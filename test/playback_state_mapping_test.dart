// Testes do item 1.9: PlaybackState completo para sistema/Bluetooth/
// Android Auto.
//
// Duas camadas cobertas:
//  1. Mapeamentos PUROS (RepeatMode/Shuffle/processingState ↔ enums do
//     audio_service) — sem plugin, sem estado.
//  2. Integração AudioService: publicar fila/índice/modos e comandos
//     vindos do SISTEMA (setRepeatMode/setShuffleMode/skipToQueueItem)
//     chegam aos callbacks como o app espera.
//
// O PlayerProvider também é exercitado: comando do sistema altera a
// fila, persiste a preferência e reemite o estado (o lock screen não
// pode ficar mostrando repeat aceso depois de desligar pelo sistema).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audio_service/audio_service.dart' as asvc;

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/audio_service.dart';

import 'support/playable_audio_service.dart';

Song _track(String name) =>
    Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

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

PlayerProvider _provider(PlayableAudioService svc, SettingsProvider prefs) {
  return PlayerProvider(
    svc,
    settings: prefs,
    songRepository: _FakeSongRepository(<Song>[
      _track('apple'),
      _track('banana'),
      _track('cherry'),
    ]),
    sessionRepository: _FakeSessionRepository(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mapeamentos puros (app ↔ audio_service)', () {
    test('RepeatMode → AudioServiceRepeatMode', () {
      expect(AudioService.systemRepeatMode(RepeatMode.off),
          asvc.AudioServiceRepeatMode.none);
      expect(AudioService.systemRepeatMode(RepeatMode.all),
          asvc.AudioServiceRepeatMode.all);
      expect(AudioService.systemRepeatMode(RepeatMode.one),
          asvc.AudioServiceRepeatMode.one);
    });

    test('AudioServiceRepeatMode → RepeatMode (ida e volta)', () {
      expect(AudioService.appRepeatMode(asvc.AudioServiceRepeatMode.none),
          RepeatMode.off);
      expect(AudioService.appRepeatMode(asvc.AudioServiceRepeatMode.all),
          RepeatMode.all);
      expect(AudioService.appRepeatMode(asvc.AudioServiceRepeatMode.one),
          RepeatMode.one);
      // group não é implementado pelo audio_service: cai em off.
      expect(AudioService.appRepeatMode(asvc.AudioServiceRepeatMode.group),
          RepeatMode.off);

      for (final RepeatMode mode
          in <RepeatMode>[RepeatMode.off, RepeatMode.all, RepeatMode.one]) {
        expect(AudioService.appRepeatMode(AudioService.systemRepeatMode(mode)),
            mode);
      }
    });

    test('shuffle → AudioServiceShuffleMode', () {
      expect(AudioService.systemShuffleMode(false),
          asvc.AudioServiceShuffleMode.none);
      expect(AudioService.systemShuffleMode(true),
          asvc.AudioServiceShuffleMode.all);
    });

    test('processingState: idle/completed/ready', () {
      expect(AudioService.systemProcessingState(PlayerStatus.idle),
          asvc.AudioProcessingState.idle);
      expect(AudioService.systemProcessingState(PlayerStatus.completed),
          asvc.AudioProcessingState.completed);
      // playing/paused/stopped todos publicam "ready" (há conteúdo carregado).
      for (final PlayerStatus status in <PlayerStatus>[
        PlayerStatus.playing,
        PlayerStatus.paused,
        PlayerStatus.stopped,
      ]) {
        expect(AudioService.systemProcessingState(status),
            asvc.AudioProcessingState.ready);
      }
    });
  });

  group('AudioService: PlaybackState publicado', () {
    late AudioService svc;

    setUp(() {
      svc = AudioService();
    });

    tearDown(() async {
      await svc.dispose();
    });

    test('publishQueue envia fila e índice ao MediaSession', () async {
      final List<Song> songs = <Song>[
        _track('apple'),
        _track('banana'),
        _track('cherry'),
      ];

      svc.publishQueue(songs, 1);

      final asvc.MediaItem published = svc.queue.value[1];
      expect(svc.queue.value, hasLength(3));
      expect(published.title, 'Banana'); // _humanize capitaliza
      expect(svc.playbackState.value.queueIndex, 1);
      expect(svc.playbackState.value.processingState,
          asvc.AudioProcessingState.idle);

      // Índice fora da fila = nada selecionado (null), não estoura.
      svc.publishQueue(songs, -1);
      expect(svc.playbackState.value.queueIndex, isNull);
    });

    test('syncModes publica repeat/shuffle aplicados', () async {
      svc.syncModes(repeat: RepeatMode.one, shuffle: true);
      expect(svc.playbackState.value.repeatMode,
          asvc.AudioServiceRepeatMode.one);
      expect(svc.playbackState.value.shuffleMode,
          asvc.AudioServiceShuffleMode.all);

      svc.syncModes(repeat: RepeatMode.off, shuffle: false);
      expect(svc.playbackState.value.repeatMode,
          asvc.AudioServiceRepeatMode.none);
      expect(svc.playbackState.value.shuffleMode,
          asvc.AudioServiceShuffleMode.none);
    });

    test('processingState completed é publicado ao final da faixa',
        () async {
      svc.status.value = PlayerStatus.completed;
      svc.syncModes(repeat: RepeatMode.off, shuffle: false);
      expect(svc.playbackState.value.processingState,
          asvc.AudioProcessingState.completed);
      expect(svc.playbackState.value.playing, isFalse);
    });

    test('posições publicadas: updatePosition + updateTime coerentes',
        () async {
      svc.position.value = const Duration(seconds: 42);
      svc.syncModes(repeat: RepeatMode.off, shuffle: false);

      final asvc.PlaybackState state = svc.playbackState.value;
      expect(state.updatePosition, const Duration(seconds: 42));
      // updateTime = agora → o sistema projeta o avanço em tempo real.
      expect(
        state.updateTime.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );
      expect(state.speed, 1.0);
    });

    test('comandos do SISTEMA chegam aos callbacks do provider', () async {
      RepeatMode? repeatSeen;
      bool? shuffleSeen;
      int? indexSeen;
      svc.onSetRepeatMode = (RepeatMode mode) async => repeatSeen = mode;
      svc.onSetShuffleMode = (bool enabled) async => shuffleSeen = enabled;
      svc.onSkipToQueueIndex = (int index) async => indexSeen = index;

      await svc.setRepeatMode(asvc.AudioServiceRepeatMode.one);
      await svc.setShuffleMode(asvc.AudioServiceShuffleMode.all);
      await svc.skipToQueueItem(7);

      expect(repeatSeen, RepeatMode.one);
      expect(shuffleSeen, isTrue);
      expect(indexSeen, 7);
    });

    test('callbacks nulos (sem provider) não lançam', () async {
      expect(() => svc.setRepeatMode(asvc.AudioServiceRepeatMode.all),
          returnsNormally);
      expect(() => svc.setShuffleMode(asvc.AudioServiceShuffleMode.none),
          returnsNormally);
      expect(() => svc.skipToQueueItem(0), returnsNormally);
    });
  });

  group('PlayerProvider: comando do sistema aplica e reemite', () {
    late PlayableAudioService svc;
    late SettingsProvider prefs;

    setUp(() async {
      svc = PlayableAudioService();
      prefs = SettingsProvider();
      await prefs.load();
    });

    tearDown(() async {
      prefs.dispose();
    });

    test('setRepeatMode do sistema muda a fila, persiste e reemite',
        () async {
      final PlayerProvider provider = _provider(svc, prefs);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      expect(provider.repeat, RepeatMode.off);

      await svc.setRepeatMode(asvc.AudioServiceRepeatMode.all);

      expect(provider.repeat, RepeatMode.all);
      expect(prefs.repeatMode, RepeatMode.all, reason: 'deve persistir');
      // Reemitido: o lock screen não pode ficar mostrando repeat antigo.
      expect(svc.playbackState.value.repeatMode,
          asvc.AudioServiceRepeatMode.all);
    });

    test('setShuffleMode do sistema liga/desliga e persiste', () async {
      final PlayerProvider provider = _provider(svc, prefs);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      expect(provider.shuffle, isFalse);

      await svc.setShuffleMode(asvc.AudioServiceShuffleMode.all);
      expect(provider.shuffle, isTrue);
      expect(prefs.shuffleEnabled, isTrue);
      expect(svc.playbackState.value.shuffleMode,
          asvc.AudioServiceShuffleMode.all);

      // Desligar pelo sistema deve restaurar a ordem e reemitir.
      await svc.setShuffleMode(asvc.AudioServiceShuffleMode.none);
      expect(provider.shuffle, isFalse);
      expect(prefs.shuffleEnabled, isFalse);
      expect(svc.playbackState.value.shuffleMode,
          asvc.AudioServiceShuffleMode.none);
    });

    test('skipToQueueItem do sistema toca o índice da fila publicada',
        () async {
      final PlayerProvider provider = _provider(svc, prefs);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      final List<Song> queue = List<Song>.of(
        svc.queue.value.map(
          (asvc.MediaItem item) =>
              provider.songs.firstWhere((Song s) => s.id == item.id),
        ),
      );
      expect(queue, hasLength(3));

      await svc.skipToQueueItem(2);
      expect(provider.currentSong?.id, queue[2].id);

      // Índice fora do intervalo é ignorado (fila encurtou no sistema).
      final Song? before = provider.currentSong;
      await svc.skipToQueueItem(99);
      await svc.skipToQueueItem(-1);
      expect(provider.currentSong?.id, before?.id);
    });
  });
}
