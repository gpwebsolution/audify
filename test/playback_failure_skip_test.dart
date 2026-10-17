// Testes do item 1.7: mensagens de erro amigáveis + skip automático
// com LIMITE de falhas seguidas ao abrir faixas.
//
// Cenário coberto: arquivo apagado/corrompido não deve travar a escuta
// (pula para a próxima), mas uma fila toda morta não pode gerar loop
// (para no teto [AudioService]-maxConsecutivePlayFailures).
//
// O AudioService é um falso SCRIPTÁCIO: falha/sucesso por faixa, mas
// seguindo o MESMO fluxo real (mensagem amigável + shouldSkipOnOpenFailure
// + onPlaybackFailed), para o provider enxergar o que veria no aparelho.

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/audio_service.dart';


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

/// AudioService que FALHA ao abrir as faixas de [failTitles] com um
/// erro de ARQUIVO (mesmo texto/classificação do plugin real) e toca
/// normalmente as demais — replicando o caminho de catch do serviço.
class _ScriptedAudioService extends AudioService {
  _ScriptedAudioService({required this.failTitles});

  final Set<String> failTitles;

  /// Quantas vezes playSong foi chamado (para o teste do limite).
  int playCalls = 0;

  static final Object _fileError =
      Exception('Unable to load asset: "x.mp3"');

  @override
  Future<void> playSong(Song song, {Duration startAt = Duration.zero}) async {
    playCalls++;
    if (failTitles.contains(song.title)) {
      // Mesmo fluxo do AudioService real: mensagem amigável primeiro,
      // depois (só para falha de arquivo) notifica o provider.
      errorMessage.value = AudioService.userMessage(
        'tocar "${song.title}"',
        _fileError,
      );
      status.value = PlayerStatus.idle;
      if (AudioService.shouldSkipOnOpenFailure(_fileError)) {
        await onPlaybackFailed?.call(song);
      }
      return;
    }
    errorMessage.value = null;
    status.value = PlayerStatus.playing;
    duration.value = song.duration ?? Duration.zero;
    position.value = Duration.zero;
  }
}

Song _track(String name) => Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

/// Catálogo na ordem que o provider entrega (alfabética):
/// Apple, Banana, Cherry, Mango, Pear.
List<Song> _fiveTracks() => [
      _track('apple'),
      _track('banana'),
      _track('cherry'),
      _track('mango'),
      _track('pear'),
    ];

PlayerProvider _provider(AudioService audio) {
  return PlayerProvider(
    audio,
    songRepository: _FakeSongRepository(_fiveTracks()),
    sessionRepository: _FakeSessionRepository(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  group('mensagens amigáveis (funções puras)', () {
    test('userMessage cita a ação e o motivo, nunca o objeto cru', () {
      final String message = AudioService.userMessage(
        'tocar "Música"',
        Exception('Unable to load asset: "a.mp3"'),
      );
      expect(message, contains('tocar "Música"'));
      expect(message, contains('Arquivo não encontrado'));
      // Sem exceção crua vazando para o usuário.
      expect(message, isNot(contains('Exception')));
      expect(message, isNot(contains('Unable to load')));
    });

    test('motivos distintos: permissão e arquivo corrompido', () {
      expect(
        AudioService.friendlyError(Exception('Permission denied')),
        contains('Sem permissão'),
      );
      expect(
        AudioService.friendlyError(Exception('data is corrupt')),
        contains('corrompido'),
      );
      // Erro não mapeado cai em mensagem genérica útil.
      expect(
        AudioService.friendlyError(Exception('algo inesperado')),
        contains('outra faixa'),
      );
    });

    test('shouldSkipOnOpenFailure: falha de arquivo sim, plataforma não',
        () {
      expect(
        AudioService.shouldSkipOnOpenFailure(
          Exception('Unable to load asset: "a.mp3"'),
        ),
        isTrue,
      );
      expect(
        AudioService.shouldSkipOnOpenFailure(Exception('file not found')),
        isTrue,
      );
      // Canal nativo morto: pular não resolveria (todas falhariam).
      expect(
        AudioService.shouldSkipOnOpenFailure(
          Exception('MissingPluginException: No implementation found'),
        ),
        isFalse,
      );
    });
  });

  group('skip automático com limite (PlayerProvider)', () {
    test('falhas seguidas param no limite e explicam o motivo', () async {
      final _ScriptedAudioService audio = _ScriptedAudioService(
        failTitles: {'Apple', 'Banana', 'Cherry', 'Mango', 'Pear'},
      );
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      // Toca a 1ª: 3 falhas seguidas (limite) e PAROU — não tentou
      // a 4ª nem entrou em loop pela fila inteira.
      await provider.playVisibleAt(0);

      expect(audio.playCalls,
          PlayerProvider.maxConsecutivePlayFailures);
      expect(provider.errorMessage, contains('Reprodução parada'));
      expect(provider.errorMessage,
          contains('${PlayerProvider.maxConsecutivePlayFailures} faixas'));
      expect(provider.status, PlayerStatus.idle);

      // Nada mais é tentado sozinho depois do teto.
      final int afterLimit = audio.playCalls;
      await provider.next();
      expect(audio.playCalls, afterLimit + 1); // só o next manual
    });

    test('sucesso no meio zera o contador (não acumula falhas)',
        () async {
      final _ScriptedAudioService audio = _ScriptedAudioService(
        // Apple e Banana falham; Cherry toca (zera); Mango e Pear
        // voltam a falhar — mas sem chegar a 3 seguidas.
        failTitles: {'Apple', 'Banana', 'Mango', 'Pear'},
      );
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);

      // 2 falhas seguidas, depois Cherry ABRIU: playSong zera o contador.
      expect(audio.playCalls, 3);
      expect(provider.currentSong!.title, 'Cherry');

      // Mango e Pear falham em seguida (1 e 2 no contador novo) e o fim
      // da fila encerra sem bater o teto. SEM o reset no sucesso, Mango
      // seria a 3ª falha seguida e o provider teria parado antes de
      // tentar Pear.
      await provider.next();
      expect(audio.playCalls, 5);
      expect(provider.currentSong!.title, 'Pear');
      expect(provider.errorMessage, isNot(contains('Reprodução parada')));
      // A mensagem amigável da última falha continua disponível.
      expect(provider.errorMessage, contains('tocar "Pear"'));
    });

    test('escolha manual do usuário zera o teto (nova chance)',
        () async {
      final _ScriptedAudioService audio = _ScriptedAudioService(
        failTitles: {'Apple', 'Banana', 'Cherry', 'Mango', 'Pear'},
      );
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      expect(audio.playCalls, 3); // limite batido

      // Usuário toca outra faixa na mão: contador zerado, tenta de novo
      // e chega ao teto uma segunda vez (3 chamadas novas).
      await provider.playVisibleAt(1);
      expect(audio.playCalls, 6);
      expect(provider.errorMessage, contains('Reprodução parada'));
    });

    test('falha de PLATAFORMA não dispara skip (só mensagem)', () async {
      // O serviço real só chama onPlaybackFailed em falha de arquivo
      // (shouldSkipOnOpenFailure) — simulamos o caso canônico: canal
      // morto. O provider não deve pular: playSong é chamado 1x só.
      final _PlatformFailAudioService audio = _PlatformFailAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);

      expect(audio.playCalls, 1);
      expect(provider.currentSong!.title, 'Apple');
      expect(provider.errorMessage, contains('tocar "Apple"'));
    });
  });
}

/// Falha de plataforma: mensagem amigável, mas SEM notificar o
/// provider (espelha o `if (shouldSkipOnOpenFailure)` do serviço).
class _PlatformFailAudioService extends AudioService {
  int playCalls = 0;

  static final Object _platformError =
      Exception('MissingPluginException: No implementation found');

  @override
  Future<void> playSong(Song song, {Duration startAt = Duration.zero}) async {
    playCalls++;
    errorMessage.value =
        AudioService.userMessage('tocar "${song.title}"', _platformError);
    status.value = PlayerStatus.idle;
    if (AudioService.shouldSkipOnOpenFailure(_platformError)) {
      await onPlaybackFailed?.call(song);
    }
  }
}
