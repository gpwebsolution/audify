// Testes do item 3.4: gapless (fila inteira no player) + crossfade 0–12 s.
//
// Cobertura:
//  - playSong com fila publicada carrega a FILA INTEIRA (children +
//    initialIndex) — transições sem reload; mesma fila → só seek;
//    sem fila → fonte única (comportamento antigo);
//  - eventos do player: transição de índice notifica o provider,
//    índice fora/descompassado é ignorado, errorCode em runtime
//    dispara onPlaybackFailed (mesmo critério do 1.7);
//  - syncModes espelha repeat no LoopMode NATIVO (off=0/one=1/all=2);
//  - crossfade: fator puro (fade-in/out, triângulo em faixa curta),
//    aplicação de volume por posição, prioridade do sono e restauração;
//  - sono "ao fim da faixa" com repeat one: fim detectado pela posição
//    (~400 ms) sem evento (o LoopMode.one repete no nativo);
//  - PlayerProvider: transição gapless muda a fila/UI sem playSong
//    novo; espúrios ignorados; sono consome sem avançar;
//  - persistência/saneamento da preferência de crossfade;
//  - regressão do auto-deadlock do AlbumArtworkCache (c175e01) que
//    travava uriFor — e, por consequência, o playSong.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/album_artwork_cache.dart';
import 'package:audify/services/audio_service.dart';

import 'support/just_audio_mock.dart';
import 'support/playable_audio_service.dart';

/// Faixa de ARQUIVO (caminho do aparelho): `_onLoad` do just_audio é
/// no-op para scheme file — sem passar pelo carregamento de asset do
/// bundle (que usaria path_provider/rootBundle).
Song _fileSong(int n) => Song.fromMediaStore(
  SongModel(<dynamic, dynamic>{
    '_id': n,
    '_data': '/storage/emulated/0/Music/faixa_$n.mp3',
    '_display_name': 'Faixa$n.mp3',
    '_display_name_wo_ext': 'Faixa$n',
    'title': 'Faixa $n',
    'artist': 'Artista',
    'album': 'Album',
    'duration': 60000,
  }),
);

Song _track(String name) => Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

List<Song> _queueOf3() => <Song>[_fileSong(1), _fileSong(2), _fileSong(3)];

class _FakeSongRepository extends SongRepository {
  final List<Song> assets;
  _FakeSongRepository(this.assets);

  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => assets;
}

class _FakeSessionRepository extends SessionRepository {
  @override
  Future<void> save(Song song, Duration position) async {}

  @override
  Future<void> saveQueue(List<String> ids, int index) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<(Song?, Duration)> load() async => (null, Duration.zero);

  @override
  Future<(List<String>, int)> loadQueue() async => (const <String>[], -1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------------------------
  // Gapless: playSong com a fila publicada
  // ------------------------------------------------------------------

  group('gapless: playSong posiciona/carrega a fila', () {
    test(
      'primeira carga carrega a FILA INTEIRA (children + initialIndex)',
      () async {
        final JustAudioMock mock = mockJustAudio();
        final AudioService svc = AudioService();
        addTearDown(svc.dispose);
        final List<Song> songs = _queueOf3();

        svc.publishQueue(songs, 1);
        await svc.playSong(songs[1]);

        final List<MethodCall> loads = mock.callsWhere('load');
        expect(loads, hasLength(1));
        final Map<Object?, Object?> args =
            loads.single.arguments as Map<Object?, Object?>;
        expect(args['initialIndex'], 1);
        final Map<Object?, Object?> source =
            args['audioSource'] as Map<Object?, Object?>;
        expect(source['type'], 'concatenating');
        expect((source['children'] as List<Object?>).length, 3);
        expect(svc.status.value, PlayerStatus.playing);
        expect(svc.errorMessage.value, isNull);
        expect(svc.mediaItem.value?.id, songs[1].id);
      },
    );

    test('mesma fila → seek, sem novo load (skip gapless)', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      final List<Song> songs = _queueOf3();

      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]);
      expect(mock.callsWhere('load'), hasLength(1));

      await svc.playSong(songs[2]);

      // Nenhuma recarga: a fila já está no player.
      expect(mock.callsWhere('load'), hasLength(1));
      expect(mock.seekIndices, <int>[2]);
      expect(svc.status.value, PlayerStatus.playing);
      expect(svc.mediaItem.value?.id, songs[2].id);
    });

    test('sem fila publicada → fonte única (serviço isolado)', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);

      await svc.playSong(_fileSong(7));

      final Map<Object?, Object?> args =
          mock.callsWhere('load').single.arguments as Map<Object?, Object?>;
      final Map<Object?, Object?> source =
          args['audioSource'] as Map<Object?, Object?>;
      expect(source['type'], 'concatenating');
      expect((source['children'] as List<Object?>).length, 1);
      expect(svc.status.value, PlayerStatus.playing);
    });

    test('fila diferente → recarrega a fila nova', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);

      final List<Song> first = _queueOf3();
      svc.publishQueue(first, 0);
      await svc.playSong(first[0]);

      final List<Song> other = <Song>[_fileSong(9), _fileSong(8)];
      svc.publishQueue(other, 0);
      await svc.playSong(other[0]);

      final List<MethodCall> loads = mock.callsWhere('load');
      expect(loads, hasLength(2));
      final Map<Object?, Object?> args =
          loads.last.arguments as Map<Object?, Object?>;
      expect(
        ((args['audioSource'] as Map)['children'] as List<Object?>).length,
        2,
      );
    });
  });

  // ------------------------------------------------------------------
  // Gapless: eventos vindos do player
  // ------------------------------------------------------------------

  group('gapless: eventos do player', () {
    test('transição de índice notifica onQueueIndexChanged', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      final List<Song> songs = _queueOf3();
      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]);

      final List<(int, Song)> events = <(int, Song)>[];
      svc.onQueueIndexChanged = (int i, Song s) => events.add((i, s));

      // O nativo avançou sozinho para a 3ª faixa (gapless).
      mock.eventSink!.success(
        mock.playbackEvent(currentIndex: 2, processingState: 3),
      );
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.first.$1, 2);
      expect(events.first.$2.id, songs[2].id);
      expect(svc.mediaItem.value?.id, songs[2].id);
    });

    test('índice fora da fila é ignorado (sem notificação)', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      final List<Song> songs = _queueOf3();
      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]);

      final List<(int, Song)> events = <(int, Song)>[];
      svc.onQueueIndexChanged = (int i, Song s) => events.add((i, s));

      // A fonte da verdade encurtou (fila trocada no provider) enquanto
      // o player segue com as 3 fontes carregadas: o índice 2 é válido
      // NO PLAYER mas fora do snapshot publicado → sem notificação.
      // (O just_audio clampeia índice acima da sequência para
      // length-1 — o cenário real de "fora de faixa" é este daqui.)
      svc.publishQueue(<Song>[songs[0]], 0);
      mock.eventSink!.success(
        mock.playbackEvent(currentIndex: 2, processingState: 3),
      );
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(svc.mediaItem.value?.id, songs[0].id);
    });

    test(
      'errorCode em runtime dispara onPlaybackFailed com a faixa morta',
      () async {
        final JustAudioMock mock = mockJustAudio();
        final AudioService svc = AudioService();
        addTearDown(svc.dispose);
        final List<Song> songs = _queueOf3();
        svc.publishQueue(songs, 0);
        await svc.playSong(songs[0]);

        final List<Song> failures = <Song>[];
        svc.onPlaybackFailed = (Song s) async => failures.add(s);

        mock.eventSink!.success(
          mock.playbackEvent(
            currentIndex: 1,
            processingState: 3,
            errorCode: 4,
            errorMessage: 'boom',
          ),
        );
        await pumpEventQueue();

        expect(failures, hasLength(1));
        expect(failures.single.id, songs[1].id);
        expect(svc.status.value, PlayerStatus.idle);
        expect(svc.errorMessage.value, isNotNull);
      },
    );

    test('syncModes espelha repeat no LoopMode nativo', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      final List<Song> songs = _queueOf3();
      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]); // ativa a plataforma (canal mockado)

      svc.syncModes(repeat: RepeatMode.one, shuffle: false);
      await pumpEventQueue();
      final List<MethodCall> one = mock.callsWhere('setLoopMode');
      expect(one, isNotEmpty);
      expect((one.last.arguments as Map)['loopMode'], 1); // one=1

      svc.syncModes(repeat: RepeatMode.all, shuffle: false);
      await pumpEventQueue();
      expect(
        (mock.callsWhere('setLoopMode').last.arguments as Map)['loopMode'],
        2, // all=2
      );

      svc.syncModes(repeat: RepeatMode.off, shuffle: false);
      await pumpEventQueue();
      expect(
        (mock.callsWhere('setLoopMode').last.arguments as Map)['loopMode'],
        0, // off=0
      );
    });
  });

  // ------------------------------------------------------------------
  // Crossfade (volume por posição)
  // ------------------------------------------------------------------

  group('crossfade (3.4)', () {
    test('fator puro: desligado a 1.0, fades nas pontas, meio a 1.0', () {
      Duration d(int s) => Duration(seconds: s);
      // Desligado / duração desconhecida: sem efeito.
      expect(AudioService.crossfadeVolumeFactor(d(10), d(60), 0), 1.0);
      expect(AudioService.crossfadeVolumeFactor(d(10), Duration.zero, 4), 1.0);
      // Fade-in: 0 s mudo, meio da janela 0.5, depois a 1.0.
      expect(AudioService.crossfadeVolumeFactor(d(0), d(60), 4), 0.0);
      expect(
        AudioService.crossfadeVolumeFactor(d(2), d(60), 4),
        closeTo(0.5, 1e-9),
      );
      expect(AudioService.crossfadeVolumeFactor(d(30), d(60), 4), 1.0);
      // Fade-out: últimos 4 s descem até 0.
      expect(
        AudioService.crossfadeVolumeFactor(d(58), d(60), 4),
        closeTo(0.5, 1e-9),
      );
      expect(AudioService.crossfadeVolumeFactor(d(60), d(60), 4), 0.0);
      expect(AudioService.crossfadeVolumeFactor(d(65), d(60), 4), 0.0);
      // Faixa mais curta que a janela: triângulo suave (menor manda).
      expect(
        AudioService.crossfadeVolumeFactor(d(1), d(3), 4),
        closeTo(0.25, 1e-9),
      );
      expect(
        AudioService.crossfadeVolumeFactor(d(2), d(3), 4),
        closeTo(0.25, 1e-9),
      );
    });

    test('tickCrossfade aplica o volume pela posição', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      // Ativa a plataforma (senão setVolume é local no player inativo e
      // não grava chamada de canal) e congela o timer de posição do
      // just_audio para o teste ser determinístico.
      final List<Song> songs = _queueOf3();
      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]);
      await svc.pause();
      await pumpEventQueue();
      svc.crossfadeSeconds = () => 4;
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);

      // Últimos 2 s de 4 → 0.5.
      svc.position.value = const Duration(seconds: 58);
      await svc.tickCrossfade();
      expect(
        (mock.callsWhere('setVolume').last.arguments as Map)['volume'],
        closeTo(0.5, 1e-9),
      );
      expect(svc.volume.value, closeTo(0.5, 1e-9));

      // Últimos 0.5 s → 0.125.
      svc.position.value = const Duration(milliseconds: 59500);
      await svc.tickCrossfade();
      expect(
        (mock.callsWhere('setVolume').last.arguments as Map)['volume'],
        closeTo(0.125, 1e-9),
      );

      // Meio da faixa → volta à base (1.0).
      svc.position.value = const Duration(seconds: 30);
      await svc.tickCrossfade();
      expect(svc.volume.value, 1.0);
      expect(
        (mock.callsWhere('setVolume').last.arguments as Map)['volume'],
        1.0,
      );
    });

    test('sono ativo tem prioridade sobre o crossfade', () async {
      final JustAudioMock mock = mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      // Mesma ativação/congelação do teste acima: as asserções de canal
      // exigem plataforma ativa (player inativo grava volume só local).
      final List<Song> songs = _queueOf3();
      svc.publishQueue(songs, 0);
      await svc.playSong(songs[0]);
      await svc.pause();
      await pumpEventQueue();
      svc.crossfadeSeconds = () => 4;
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);

      svc.position.value = const Duration(seconds: 58);
      await svc.tickCrossfade();
      expect(svc.volume.value, closeTo(0.5, 1e-9));

      // Sono ligado: o tick do crossfade NÃO mexe mais no volume.
      svc.startSleepAtTrackEnd();
      final int before = mock.callsWhere('setVolume').length;
      svc.position.value = const Duration(seconds: 59);
      await svc.tickCrossfade();
      expect(mock.callsWhere('setVolume').length, before);
      expect(svc.volume.value, closeTo(0.5, 1e-9));

      // Cancelar o sono restaura a base.
      svc.cancelSleepTimer();
      await pumpEventQueue();
      expect(svc.volume.value, 1.0);
      expect(
        (mock.callsWhere('setVolume').last.arguments as Map)['volume'],
        1.0,
      );
    });

    test('crossfade desligado no meio da janela restaura 1.0', () async {
      mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      svc.crossfadeSeconds = () => 4;
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);

      svc.position.value = const Duration(seconds: 58);
      await svc.tickCrossfade();
      expect(svc.volume.value, closeTo(0.5, 1e-9));

      // Usuário desligou o crossfade em Configurações → próximo tick sai
      // da janela (getter é lido ao vivo).
      svc.crossfadeSeconds = () => 0;
      await svc.tickCrossfade();
      expect(svc.volume.value, 1.0);
    });

    test('pausado sai da janela (volume volta a 1.0)', () async {
      mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      svc.crossfadeSeconds = () => 4;
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);
      svc.position.value = const Duration(seconds: 58);
      await svc.tickCrossfade();
      expect(svc.volume.value, closeTo(0.5, 1e-9));

      svc.status.value = PlayerStatus.paused;
      await svc.tickCrossfade();
      expect(svc.volume.value, 1.0);
    });
  });

  // ------------------------------------------------------------------
  // Sono "ao fim da faixa" com repeat one (gatilho ε)
  // ------------------------------------------------------------------

  group('"ao fim da faixa" com repeat one (3.4)', () {
    test('fim da faixa detectado pela posição consome o timer', () async {
      mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      svc.syncModes(repeat: RepeatMode.one, shuffle: false);
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);
      svc.position.value = const Duration(milliseconds: 59700);
      svc.startSleepAtTrackEnd();

      expect(await svc.checkSleepTimer(), isTrue);
      await pumpEventQueue();
      expect(svc.sleepTimerActive, isFalse);
      expect(svc.status.value, PlayerStatus.idle);
      // One-shot: o próximo check não consome de novo.
      expect(await svc.checkSleepTimer(), isFalse);
    });

    test('longe do fim não consome (timer segue ativo)', () async {
      mockJustAudio();
      final AudioService svc = AudioService();
      addTearDown(svc.dispose);
      svc.syncModes(repeat: RepeatMode.one, shuffle: false);
      // Assenta os replays do construtor (playerState idle, duration)
      // ANTES de fixar o estado manual: sem isso o replay chega no
      // primeiro await e sobrescreve o status para idle.
      await pumpEventQueue();
      svc.status.value = PlayerStatus.playing;
      svc.duration.value = const Duration(seconds: 60);
      svc.position.value = const Duration(seconds: 10);
      svc.startSleepAtTrackEnd();

      expect(await svc.checkSleepTimer(), isFalse);
      expect(svc.sleepTimerActive, isTrue);
      expect(svc.status.value, PlayerStatus.playing);
    });

    test(
      'com repeat off o ε não dispara (eventos normais cuidam disso)',
      () async {
        mockJustAudio();
        final AudioService svc = AudioService();
        addTearDown(svc.dispose);
        svc.syncModes(repeat: RepeatMode.off, shuffle: false);
        svc.status.value = PlayerStatus.playing;
        svc.duration.value = const Duration(seconds: 60);
        svc.position.value = const Duration(milliseconds: 59700);
        svc.startSleepAtTrackEnd();

        expect(await svc.checkSleepTimer(), isFalse);
        expect(svc.sleepTimerActive, isTrue);
        // Consumo normal (papel do provider via completed/transição).
        expect(svc.consumeSleepAtTrackEnd(), isTrue);
        await pumpEventQueue();
        expect(svc.sleepTimerActive, isFalse);
      },
    );
  });

  // ------------------------------------------------------------------
  // PlayerProvider: a fila avança sem recarregar
  // ------------------------------------------------------------------

  group('PlayerProvider: transição gapless', () {
    late PlayableAudioService audio;
    late PlayerProvider provider;
    final List<Song> tracks = <Song>[
      _track('alpha'),
      _track('beta'),
      _track('gamma'),
    ];

    setUp(() async {
      audio = PlayableAudioService();
      provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(tracks),
        sessionRepository: _FakeSessionRepository(),
      );
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0);
    });

    test(
      'evento do player muda a faixa sem playSong novo (sem reload)',
      () async {
        expect(provider.currentSong!.title, 'Alpha');
        final int playedBefore = audio.played.length;

        audio.onQueueIndexChanged!(2, tracks[2]);
        await pumpEventQueue();

        expect(provider.currentSong!.title, 'Gamma');
        expect(provider.isPlaying, isTrue);
        // Gapless: NENHUM playSong extra (o player já carregou a fila).
        expect(audio.played.length, playedBefore);
      },
    );

    test('evento com id divergente é ignorado (espúrio)', () async {
      audio.onQueueIndexChanged!(1, _track('delta')); // queue[1] é Beta
      await pumpEventQueue();

      expect(provider.currentSong!.title, 'Alpha');
    });

    test('sono ao fim da faixa: consome sem recarregar a fila', () async {
      final int playedBefore = audio.played.length;
      provider.startSleepAtTrackEnd();
      expect(provider.sleepTimerActive, isTrue);

      // A faixa terminou e a NEXT já começou (gapless) — o serviço
      // notifica e o provider consome o sono no MESMO evento.
      audio.onQueueIndexChanged!(1, tracks[1]);
      await pumpEventQueue();

      expect(provider.currentSong!.title, 'Beta');
      expect(provider.sleepTimerActive, isFalse);
      expect(audio.played.length, playedBefore);
    });
  });

  // ------------------------------------------------------------------
  // Preferência de crossfade (persistência + saneamento)
  // ------------------------------------------------------------------

  group('preferência de crossfade (settings)', () {
    test('default 0, persiste entre instâncias e saneia a faixa', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      expect(settings.crossfadeSeconds, 0);

      await settings.setCrossfadeSeconds(8);
      expect(settings.crossfadeSeconds, 8);

      final SettingsProvider reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.crossfadeSeconds, 8);

      // Fora da faixa 0–12 cai no teto/piso.
      await settings.setCrossfadeSeconds(99);
      expect(settings.crossfadeSeconds, SettingsProvider.maxCrossfadeSeconds);
      await settings.setCrossfadeSeconds(-3);
      expect(settings.crossfadeSeconds, 0);
      expect(SettingsProvider.maxCrossfadeSeconds, 12);

      // Disco corrompido também é saneado no load.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'crossfade_seconds': 42,
      });
      final SettingsProvider corrupt = SettingsProvider();
      await corrupt.load();
      expect(corrupt.crossfadeSeconds, SettingsProvider.maxCrossfadeSeconds);
    });
  });

  // ------------------------------------------------------------------
  // Regressão: deadlock do cache de capa (bug latente c175e01)
  // ------------------------------------------------------------------

  group('bug latente: AlbumArtworkCache sem auto-deadlock', () {
    test('load com canal nativo ausente COMPLETA (devolve null)', () async {
      // O whenComplete devolvia o próprio future e o load nunca
      // completava — uriFor travaria e o playSong junto (item 3.4
      // depende de uriFor). O timeout aqui é só a rede de segurança
      // do teste: o retorno tem que chegar RÁPIDO.
      final Object? art = await AlbumArtworkCache.instance
          .load(987654)
          .timeout(const Duration(seconds: 5));
      expect(art, isNull);
    });
  });
}
