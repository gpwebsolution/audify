// Testes do item 2.4 — catálogo: abrir rápido e atualizar sozinho.
//
//  - Snapshot leve (JSON) gravado em pasta temporária de verdade
//    (CatalogSnapshotService injetado com directory);
//  - boot com snapshot: a lista aparece ANTES de a varredura terminar
//    (scan travado num Completer para provar);
//  - reconciliação: mudança no repositório aparece; igualdade não
//    notifica a UI;
//  - onAppResumed com throttle de 30s (relógio injetável) e
//    pull-to-refresh que ignora o throttle;
//  - medição do tempo de abertura antes/depois (5.000 faixas).
//
// Roda em teste COMUM (zona real): isolate (compute) e arquivo
// respondem normalmente — sob testWidgets/FakeAsync ambos travam.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/catalog_snapshot_service.dart';

import 'support/playable_audio_service.dart';

class _FakeRepo extends SongRepository {
  List<Song> device;
  List<Song> assets = const <Song>[];
  Duration delay;

  /// Quando presente, loadDeviceSongs trava até completar — prova de
  /// que o boot NÃO espera a varredura.
  Completer<void>? gate;
  int scans = 0;

  _FakeRepo({
    required this.device,
    this.delay = Duration.zero,
    this.gate,
  });

  @override
  Future<List<Song>> loadDeviceSongs() async {
    scans++;
    if (gate != null) await gate!.future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return device;
  }

  @override
  Future<List<Song>> loadAssetSongs() async => assets;
}

class _FakeSession extends SessionRepository {
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

Song _song({required String id, required String title}) =>
    Song.fromStored(<String, Object?>{
      'song_id': id,
      'title': title,
      'file_path': '/fake/$id.mp3',
      'is_asset': 0,
    })!;

/// Catálogo grande (títulos ordenáveis e > limite do compute).
List<Song> _many(int n) => <Song>[
      for (int i = 0; i < n; i++)
        _song(
          id: 't$i',
          title: 'Faixa ${i.toString().padLeft(4, '0')}',
        ),
    ];

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('audify_snapshot_test');

Future<void> _waitUntil(
  bool Function() ok, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsed > timeout) {
      fail('condição não alcançada em ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Espera um período fixo (para futures em background sem condição
/// observável, ex.: save em disco).
Future<void> _quiet([Duration time = const Duration(milliseconds: 200)]) =>
    Future<void>.delayed(time);

PlayerProvider _provider(
  _FakeRepo repo,
  CatalogSnapshotService? snapshot, {
  DateTime Function()? clock,
}) =>
    PlayerProvider(
      PlayableAudioService(),
      songRepository: repo,
      sessionRepository: _FakeSession(),
      snapshotService: snapshot,
      clock: clock,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockAudioplayersChannels);

  group('CatalogSnapshotService', () {
    test('roundtrip: save + load devolve as mesmas faixas', () async {
      final Directory dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final CatalogSnapshotService snap =
          CatalogSnapshotService(directory: () async => dir);

      final List<Song> songs = <Song>[
        _song(id: 'x1', title: 'Ação ao Vivo'),
        _song(id: 'x2', title: 'Zebra'),
      ];
      await snap.save(songs);

      final List<Song>? loaded = await snap.load();
      expect(loaded, hasLength(2));
      expect(loaded!.map((Song s) => s.id).toList(), <String>['x1', 'x2']);
      expect(loaded.first.title, 'Ação ao Vivo');
      expect(loaded.first.filePath, '/fake/x1.mp3');
    });

    test('JSON corrompido ou versão futura degrada para null', () async {
      final Directory dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file =
          File('${dir.path}/${CatalogSnapshotService.fileName}');
      final CatalogSnapshotService snap =
          CatalogSnapshotService(directory: () async => dir);

      file.writeAsStringSync('{isso não é json');
      expect(await snap.load(), isNull, reason: 'corrompido → sem snapshot');

      file.writeAsStringSync('{"version": 99, "songs": []}');
      expect(await snap.load(), isNull, reason: 'versão futura → ignora');

      // Sem arquivo nenhuma: primeira execução.
      file.deleteSync();
      expect(await snap.load(), isNull);
    });
  });

  group('PlayerProvider: snapshot e reconciliação (2.4)', () {
    test('boot com snapshot: lista visível ANTES de o scan terminar',
        () async {
      final Directory dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final CatalogSnapshotService snap =
          CatalogSnapshotService(directory: () async => dir);
      final List<Song> catalog = _many(1000);

      // Aquecimento: caminho frio grava o snapshot (compute roda aqui —
      // zona real).
      final _FakeRepo warming =
          _FakeRepo(device: catalog, delay: const Duration(milliseconds: 50));
      final PlayerProvider warm = _provider(warming, snap);
      await warm.init();
      warm.dispose();
      await _waitUntil(
        () => File('${dir.path}/${CatalogSnapshotService.fileName}')
            .existsSync(),
      );

      // Boot 2 com a varredura TRAVADA no gate.
      final Completer<void> gate = Completer<void>();
      final _FakeRepo repo = _FakeRepo(device: catalog, gate: gate);
      final PlayerProvider provider = _provider(repo, snap);
      addTearDown(provider.dispose);

      await provider.init();

      expect(provider.songs, hasLength(1000),
          reason: 'lista completa vem do SNAPSHOT, sem esperar o scan');
      expect(provider.isLoading, isFalse);
      expect(repo.scans, 1,
          reason: 'a varredura foi disparada em segundo plano (e está '
              'travada no gate — se o boot esperasse, init não teria '
              'retornado)');

      int notifies = 0;
      provider.addListener(() => notifies++);
      gate.complete();
      await _quiet();

      expect(repo.scans, 1);
      expect(notifies, 0,
          reason: 'scan com o MESMO conteúdo = reconciliação silenciosa');
      expect(provider.songs, hasLength(1000));
    });

    test('reconciliação: faixa nova aparece; pull igual não notifica',
        () async {
      final Directory dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final CatalogSnapshotService snap =
          CatalogSnapshotService(directory: () async => dir);

      final List<Song> three = <Song>[
        _song(id: 'a', title: 'Faixa A'),
        _song(id: 'b', title: 'Faixa B'),
        _song(id: 'c', title: 'Faixa C'),
      ];
      final _FakeRepo first = _FakeRepo(device: three);
      final PlayerProvider warm = _provider(first, snap);
      await warm.init();
      warm.dispose();
      await _waitUntil(
        () => File('${dir.path}/${CatalogSnapshotService.fileName}')
            .existsSync(),
      );

      // O repositório ganhou UMA faixa fora do app.
      final _FakeRepo repo = _FakeRepo(
        device: <Song>[
          ...three,
          _song(id: 'd', title: 'Faixa D'),
        ],
      );
      final PlayerProvider provider = _provider(repo, snap);
      addTearDown(provider.dispose);

      await provider.init();
      // Snapshot ainda tem 3; a reconciliação de fundo deve trazer a 4ª.
      await _waitUntil(() => provider.songs.length == 4);
      expect(provider.songs.map((Song s) => s.id), contains('d'));

      // Pull-to-refresh SEM mudança: silêncio na UI.
      int notifies = 0;
      provider.addListener(() => notifies++);
      await provider.rescanCatalog();
      expect(notifies, 0, reason: 'conteúdo igual → sem rebuild');

      // Pull-to-refresh COM mudança: aparece e notifica 1x.
      repo.device = <Song>[...repo.device, _song(id: 'e', title: 'Faixa E')];
      await provider.rescanCatalog();
      expect(provider.songs.length, 5);
      expect(notifies, 1);
    });

    test('onAppResumed re-escaneia com throttle de 30s; pull ignora',
        () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final _FakeRepo repo = _FakeRepo(device: <Song>[
        _song(id: 'a', title: 'Faixa A'),
      ]);
      final PlayerProvider provider = _provider(repo, null, clock: () => now);
      addTearDown(provider.dispose);

      await provider.init();
      await _quiet();
      final int afterBoot = repo.scans;
      expect(afterBoot, greaterThan(0));

      // Retorno imediato (dentro da janela): não varre de novo.
      provider.onAppResumed();
      await _quiet();
      expect(repo.scans, afterBoot,
          reason: 'throttle: boot acabou de varrer');

      // Passou da janela: varre.
      now = now.add(PlayerProvider.catalogRescanThrottle +
          const Duration(seconds: 1));
      provider.onAppResumed();
      await _waitUntil(() => repo.scans == afterBoot + 1);
      // O contador incrementa no COMEÇO da varredura; espera a
      // reconciliação terminar (in-flight) antes do próximo passo —
      // senão o pull seria deduplicado pelo guard.
      await _quiet();

      // Pull-to-refresh é ação explícita: ignora o throttle.
      await provider.rescanCatalog();
      expect(repo.scans, afterBoot + 2);
    });

    test('MEDICIÓN: abertura de 5.000 faixas antes (caminho frio) vs '
        'depois (snapshot)', () async {
      final Directory dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final CatalogSnapshotService snap =
          CatalogSnapshotService(directory: () async => dir);
      final List<Song> catalog = _many(5000);

      // ANTES: primeira execução — snapshot vazio, scan de verdade
      // (atraso artificial de 400ms = "MediaStore lento").
      final _FakeRepo coldRepo = _FakeRepo(
        device: catalog,
        delay: const Duration(milliseconds: 400),
      );
      final Stopwatch swCold = Stopwatch()..start();
      final PlayerProvider cold = _provider(coldRepo, snap);
      await cold.init();
      swCold.stop();
      cold.dispose();
      expect(swCold.elapsedMilliseconds, greaterThanOrEqualTo(400),
          reason: 'caminho frio espera a varredura inteira');
      // O save roda em background: espera gravar antes do boot quente.
      await _waitUntil(
        () => File('${dir.path}/${CatalogSnapshotService.fileName}')
            .existsSync(),
      );
      await _quiet();

      // DEPOIS: mesmo snapshot — a lista vem do disco e o scan segue
      // em segundo plano (repo sem atraso para não pendurar o teste).
      final _FakeRepo warmRepo = _FakeRepo(device: catalog);
      final Stopwatch swWarm = Stopwatch()..start();
      final PlayerProvider warm = _provider(warmRepo, snap);
      await warm.init();
      swWarm.stop();

      debugPrint(
        '[2.4] abertura 5.000 faixas: ANTES ${swCold.elapsedMilliseconds}ms '
        '(caminho frio), DEPOIS ${swWarm.elapsedMilliseconds}ms (snapshot)',
      );

      expect(warm.songs, hasLength(5000));
      expect(swWarm.elapsed, lessThan(swCold.elapsed),
          reason: 'snapshot tem que vencer o caminho frio');
      expect(swWarm.elapsedMilliseconds, lessThan(400),
          reason: 'boot quente não pode esperar o scan (400ms)');

      await _quiet(const Duration(milliseconds: 400));
      warm.dispose();
    });
  });
}
