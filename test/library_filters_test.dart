// Testes do item 2.5 — filtros da biblioteca: duração mínima e pastas
// ignoradas (Configurações > Biblioteca), aplicados ao catálogo e
// persistidos.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';

import 'support/playable_audio_service.dart';

Song _song({
  required String id,
  required String title,
  Duration? duration,
  String? filePath,
  bool isAsset = false,
}) => Song.fromStored(<String, Object?>{
  'song_id': id,
  'title': title,
  'file_path': filePath,
  'asset_path': isAsset ? 'assets/songs/$id.mp3' : null,
  'duration_ms': duration?.inMilliseconds,
  'is_asset': isAsset ? 1 : 0,
})!;

class _FakeRepo extends SongRepository {
  final List<Song> device;
  int scans = 0;
  _FakeRepo(this.device);

  @override
  Future<List<Song>> loadDeviceSongs() async {
    scans++;
    return device;
  }

  @override
  Future<List<Song>> loadAssetSongs() async => const <Song>[];
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

List<String> _ids(PlayerProvider provider) =>
    provider.songs.map((Song s) => s.id).toList(growable: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('filterDeviceSongs (2.5)', () {
    final List<Song> catalog = <Song>[
      _song(
        id: 'curta',
        title: 'Toque curto',
        duration: const Duration(seconds: 5),
        filePath: '/music/toque.mp3',
      ),
      _song(
        id: 'limite',
        title: 'No limite',
        duration: const Duration(seconds: 30),
        filePath: '/music/limite.mp3',
      ),
      _song(
        id: 'longa',
        title: 'Faixa longa',
        duration: const Duration(minutes: 4),
        filePath: '/music/longa.mp3',
      ),
      _song(
        id: 'sem_dur',
        title: 'Sem duração',
        filePath: '/music/desconhecida.mp3',
      ),
      _song(
        id: 'wa',
        title: 'Áudio do WhatsApp',
        duration: const Duration(minutes: 3),
        filePath: '/storage/emulated/0/WhatsApp/Audio/notas.opus',
      ),
      _song(id: 'asset', title: 'Asset do app', duration: null, isAsset: true),
    ];

    test('duração mínima: 0 desliga; 30 s esconde só a faixa curta', () {
      expect(
        PlayerProvider.filterDeviceSongs(
          catalog,
          minDurationSeconds: 0,
          ignoredFolders: const <String>[],
        ),
        hasLength(6),
        reason: 'padrão: nada é filtrado',
      );

      final List<Song> filtered = PlayerProvider.filterDeviceSongs(
        catalog,
        minDurationSeconds: 30,
        ignoredFolders: const <String>[],
      );
      expect(
        filtered.map((Song s) => s.id),
        <String>['limite', 'longa', 'sem_dur', 'wa', 'asset'],
        reason:
            '5 s cai; 30 s (igual ao mínimo) passa; duração null '
            'e asset passam por segurança',
      );
    });

    test('pastas ignoradas: prefixo com limite de diretório', () {
      final List<Song> filtered = PlayerProvider.filterDeviceSongs(
        catalog,
        minDurationSeconds: 0,
        ignoredFolders: const <String>['/storage/emulated/0/WhatsApp/Audio'],
      );
      expect(
        filtered.map((Song s) => s.id),
        isNot(contains('wa')),
        reason: 'arquivo DENTRO da pasta some',
      );
      expect(
        filtered.map((Song s) => s.id),
        containsAll(<String>['curta', 'longa']),
        reason: 'outras pastas continuam',
      );

      final List<Song> boundary = PlayerProvider.filterDeviceSongs(
        <Song>[
          _song(id: 'ok', title: 'Embaixo', filePath: '/music/rock/funk.mp3'),
          _song(
            id: 'falso',
            title: 'Prefixo parecido',
            filePath: '/music/rockabilly/funk.mp3',
          ),
          _song(
            id: 'raiz',
            title: 'Na própria pasta',
            filePath: '/music/rock/funk.mp3',
          ),
        ],
        minDurationSeconds: 0,
        ignoredFolders: const <String>['/music/rock'],
      );
      expect(boundary.map((Song s) => s.id), <String>[
        'falso',
      ], reason: '/music/rock/ pega subpastas mas NÃO /music/rockabilly/');
    });

    test('as duas regras juntas', () {
      final List<Song> filtered = PlayerProvider.filterDeviceSongs(
        catalog,
        minDurationSeconds: 30,
        ignoredFolders: const <String>['/storage/emulated/0/WhatsApp/Audio'],
      );
      expect(filtered.map((Song s) => s.id), <String>[
        'limite',
        'longa',
        'sem_dur',
        'asset',
      ]);
    });
  });

  group('SettingsProvider: persistência dos filtros (2.5)', () {
    test('duração mínima e pastas passam para a próxima sessão', () async {
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      expect(settings.libraryMinDurationSeconds, 0, reason: 'padrão desligado');
      expect(settings.ignoredFolders, isEmpty);

      await settings.setLibraryMinDuration(30);
      final bool added = await settings.addIgnoredFolder(
        '/storage/emulated/0/WhatsApp/Audio/  ',
      );

      expect(added, isTrue);
      expect(
        settings.ignoredFolders.single,
        '/storage/emulated/0/WhatsApp/Audio',
        reason: 'trim + sem barra final na gravação',
      );

      final SettingsProvider restored = SettingsProvider();
      await restored.load();
      expect(restored.libraryMinDurationSeconds, 30);
      expect(restored.ignoredFolders, <String>[
        '/storage/emulated/0/WhatsApp/Audio',
      ]);
    });

    test('valores inválidos, duplicatas e remoção', () async {
      final SettingsProvider settings = SettingsProvider();
      await settings.load();

      await settings.setLibraryMinDuration(7);
      expect(
        settings.libraryMinDurationSeconds,
        0,
        reason: '7 não está em minDurationOptions',
      );

      expect(await settings.addIgnoredFolder('/pasta/'), isTrue);
      expect(
        await settings.addIgnoredFolder('/pasta'),
        isFalse,
        reason: 'duplicata (a normalização bate com a gravada)',
      );
      expect(
        await settings.addIgnoredFolder('   '),
        isFalse,
        reason: 'vazio não vira pasta',
      );
      expect(
        await settings.addIgnoredFolder('/'),
        isFalse,
        reason: 'raiz é useless e é rejeitada',
      );

      expect(await settings.removeIgnoredFolder('/pasta'), isTrue);
      expect(settings.ignoredFolders, isEmpty);
      expect(await settings.removeIgnoredFolder('/pasta'), isFalse);
    });
  });

  group('PlayerProvider aplica os filtros no catálogo (2.5)', () {
    late _FakeRepo repo;
    late SettingsProvider settings;

    setUp(() {
      repo = _FakeRepo(<Song>[
        _song(
          id: 'curta',
          title: 'Toque',
          duration: const Duration(seconds: 5),
          filePath: '/music/toque.mp3',
        ),
        _song(
          id: 'longa',
          title: 'Faixa',
          duration: const Duration(minutes: 3),
          filePath: '/music/faixa.mp3',
        ),
        _song(
          id: 'wa',
          title: 'WhatsApp',
          duration: const Duration(minutes: 2),
          filePath: '/storage/0/WhatsApp/Audio/msg.opus',
        ),
      ]);
      settings = SettingsProvider();
    });

    tearDown(() => settings.dispose());

    test('boot filtra; mudou o filtro → rescanCatalog re-aplica', () async {
      final PlayerProvider provider = PlayerProvider(
        PlayableAudioService(),
        songRepository: repo,
        sessionRepository: _FakeSession(),
        settings: settings,
      );
      addTearDown(provider.dispose);
      await provider.init();

      expect(
        _ids(provider),
        <String>['longa', 'curta', 'wa'],
        reason:
            'sem filtro ativo, tudo aparece (ordem natural: '
            'Faixa < Toque < WhatsApp)',
      );

      // Duração mínima de 30 s → o toque de 5 s some.
      await settings.setLibraryMinDuration(30);
      await provider.rescanCatalog();
      expect(_ids(provider), <String>['longa', 'wa']);

      // Pasta do WhatsApp some também.
      await settings.addIgnoredFolder('/storage/0/WhatsApp/Audio');
      await provider.rescanCatalog();
      expect(_ids(provider), <String>['longa']);

      // Desligou os dois → volta tudo.
      await settings.setLibraryMinDuration(0);
      await settings.removeIgnoredFolder('/storage/0/WhatsApp/Audio');
      await provider.rescanCatalog();
      expect(_ids(provider), <String>['longa', 'curta', 'wa']);
    });

    test(
      'a reconciliação em segundo plano (onAppResumed) mantém o filtro',
      () async {
        DateTime now = DateTime(2026, 1, 1, 12);
        final PlayerProvider provider = PlayerProvider(
          PlayableAudioService(),
          songRepository: repo,
          sessionRepository: _FakeSession(),
          settings: settings,
          clock: () => now,
        );
        addTearDown(provider.dispose);
        await settings.setLibraryMinDuration(30);
        await provider.init();
        expect(_ids(provider), <String>['longa', 'wa']);
        final int scansAfterBoot = repo.scans;

        // Fora da janela de throttle: o resume varre de verdade...
        now = now.add(
          PlayerProvider.catalogRescanThrottle + const Duration(seconds: 1),
        );
        provider.onAppResumed();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          repo.scans,
          scansAfterBoot + 1,
          reason: 'resume fora do throttle dispara re-scan',
        );
        expect(_ids(provider), <String>[
          'longa',
          'wa',
        ], reason: 're-scan automático re-filtra (não devolve o filtrado)');
      },
    );
  });
}
