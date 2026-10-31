// Testes do item 4.3 — ordenação escolhível da biblioteca.
//
// Camadas: PlayerProvider.setSort (visível reordena, fila intacta,
// persistência nas preferências), modo agrupado (álbum por número da
// faixa) e o menu "Ordenar" da aba Música.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/models/song_sort_key.dart';
import 'package:audify/providers/history_provider.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/services/playlist_database.dart';

import 'support/playable_audio_service.dart';

Song _song(
  String id,
  String title, {
  String? artist,
  String? album,
  int? durationMs,
  int? dateAdded,
  int? track,
}) => Song.fromStored(<String, Object?>{
  'song_id': id,
  'title': title,
  'artist': artist,
  'album': album,
  'duration_ms': durationMs,
  'date_added': dateAdded,
  'track_number': track,
  'is_asset': 1,
})!;

/// Catálogo conhecido: A(30s, art. Alpha, álbum X, track 3),
/// B(10s, art. Beta, álbum X, track 1), C(20s, art. Alpha, álbum X,
/// track 2).
List<Song> _catalog() => <Song>[
  _song('1', 'A', artist: 'Alpha', album: 'X', durationMs: 30000, track: 3),
  _song('2', 'B', artist: 'Beta', album: 'X', durationMs: 10000, track: 1),
  _song('3', 'C', artist: 'Alpha', album: 'X', durationMs: 20000, track: 2),
];

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

PlayerProvider _provider({SettingsProvider? settings, List<Song>? catalog}) =>
    PlayerProvider(
      PlayableAudioService(),
      songRepository: _FakeSongRepository(catalog ?? _catalog()),
      sessionRepository: _FakeSessionRepository(),
      settings: settings,
    );

List<String> _visibleTitles(PlayerProvider provider) => [
  for (final Song s in provider.visibleSongs) s.title,
];

List<String> _titlesOf(Iterable<Song> songs) => [
  for (final Song s in songs) s.title,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Diretório exclusivo desta suíte: outras suítes rodam em paralelo
    // e apagam o audify.db compartilhado do cwd (corrida de arquivo).
    await databaseFactory.setDatabasesPath(
      Directory.systemTemp.createTempSync('audify_music_sort_').path,
    );
  });

  setUp(() async {
    await PlaylistDatabase.close();
    await databaseFactory.deleteDatabase(
      p.join(await getDatabasesPath(), 'audify.db'),
    );
    HistoryProvider.instance.resetForTest();
  });

  tearDownAll(() async {
    await PlaylistDatabase.close();
  });

  group('PlayerProvider — ordenação escolhível (4.3)', () {
    test('padrão: título natural do catálogo (nenhuma surpresa)', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      expect(_visibleTitles(provider), <String>['A', 'B', 'C']);
    });

    test('setSort reordena a visível e mantém a fila de fora', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0); // fila = visível inteira, na A
      expect(_titlesOf(provider.queue), <String>['A', 'B', 'C']);

      await provider.setSort(key: SongSortKey.duration, ascending: false);
      // Mais longa primeiro (A=30s, C=20s, B=10s) — mas a fila montada
      // na escuta NÃO acompanha: mesma ordem de sempre.
      expect(_visibleTitles(provider), <String>['A', 'C', 'B']);
      expect(_titlesOf(provider.queue), <String>['A', 'B', 'C']);

      // Sentido troca sem mudar o critério; fila segue intacta.
      await provider.setSort(key: SongSortKey.duration, ascending: true);
      expect(_visibleTitles(provider), <String>['B', 'C', 'A']);
      expect(_titlesOf(provider.queue), <String>['A', 'B', 'C']);
    });

    test('busca e ordenação coexistem (só o recorte sai ordenado)', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();

      provider.setSearchQuery('Alpha'); // A e C
      await provider.setSort(key: SongSortKey.duration, ascending: true);
      expect(_visibleTitles(provider), <String>['C', 'A']);
    });

    test('persiste nas preferências e volta no boot seguinte', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();

      final PlayerProvider provider = _provider(settings: settings);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.setSort(key: SongSortKey.dateAdded, ascending: false);
      expect(settings.sortKey, SongSortKey.dateAdded);
      expect(settings.sortAscending, isFalse);

      // "Boot seguinte": novo settings lê o disco e o provider novo
      // nasce já ordenado por ele.
      final SettingsProvider reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.sortKey, SongSortKey.dateAdded);
      expect(reloaded.sortAscending, isFalse);

      final PlayerProvider nextBoot = _provider(settings: reloaded);
      addTearDown(nextBoot.dispose);
      await nextBoot.init();
      expect(nextBoot.sortKey, SongSortKey.dateAdded);
      expect(nextBoot.sortAscending, isFalse);
      // Datas nulas (assets) todas no fim; sem nenhuma conhecida, o
      // desempate por título é INVERTIDO junto com o sentido.
      expect(_visibleTitles(nextBoot), <String>['C', 'B', 'A']);
    });

    test('"Mais tocadas" usa o histórico (4.2) como pesos', () async {
      await PlaylistDatabase.recordPlay('3', playedAtMs: 10); // C ×1
      await PlaylistDatabase.recordPlay('2', playedAtMs: 20); // B ×2
      await PlaylistDatabase.recordPlay('2', playedAtMs: 30);
      await HistoryProvider.instance.load();

      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      await provider.setSort(key: SongSortKey.mostPlayed, ascending: false);
      expect(_visibleTitles(provider), <String>['B', 'C', 'A']);

      HistoryProvider.instance.resetForTest();
    });

    test('kicker: título asc volta ao normal', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      await provider.setSort(key: SongSortKey.duration, ascending: false);
      await provider.setSort(key: SongSortKey.title, ascending: true);
      expect(_visibleTitles(provider), <String>['A', 'B', 'C']);
    });
  });

  group('modo agrupado — álbum por número da faixa (4.3)', () {
    test('grupo do álbum ignora o sentido global e vai por track', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      // Ordem de catálogo é por título (A, B, C) com tracks 3, 1, 2.
      final List<SongGroup> groups = provider.visibleGroups(
        MusicGroupMode.album,
      );
      expect(groups.single.key, 'X');
      expect(
        [for (final Song s in groups.single.songs) s.title],
        <String>['B', 'C', 'A'], // track 1, 2, 3 — não A, B, C
      );
    });

    test('fora do álbum os grupos mantêm a ordem global', () async {
      final PlayerProvider provider = _provider();
      addTearDown(provider.dispose);
      await provider.init();
      final List<SongGroup> groups = provider.visibleGroups(
        MusicGroupMode.artist,
      );
      final SongGroup alpha = groups.firstWhere(
        (SongGroup g) => g.key == 'Alpha',
      );
      // Alpha tem A(track 3) e C(track 2): ordem TÍTULO, não track.
      expect([for (final Song s in alpha.songs) s.title], <String>['A', 'C']);
    });
  });

  group('menu "Ordenar" da aba Música (4.3)', () {
    testWidgets('escolhe critério, sentindo e persiste', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      final PlayerProvider provider = _provider(settings: settings);
      addTearDown(provider.dispose);
      await provider.init();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<PlayerProvider>.value(
              value: provider,
              child: const MusicScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Ordem padrão (título): A, B, C — C é a última da lista.
      expect(
        tester.getTopLeft(find.text('A')).dy,
        lessThan(tester.getTopLeft(find.text('C')).dy),
      );

      // Abre o menu: critério vigente marcado + ação de sentido.
      await tester.tap(find.byTooltip('Ordenar'));
      await tester.pumpAndSettle();
      expect(find.text('Título'), findsOneWidget);
      expect(find.text('Duração'), findsOneWidget);
      expect(find.text('Ordem decrescente'), findsOneWidget);

      // Critério novo (mantém o sentido atual — crescente). O centro
      // do rótulo caiu fora do próprio RenderParagraph do menu, mas o
      // toque ainda seleciona o item (warnIfMissed: false).
      await tester.tap(find.text('Duração'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(provider.sortKey, SongSortKey.duration);
      expect(provider.sortAscending, isTrue);
      // 10s < 20s < 30s: B, C, A.
      expect(
        tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy),
      );

      // Sentido: continua crescente, então o item vira "Ordem
      // decrescente" (o que o toque faria) — e o toque inverte.
      await tester.tap(find.byTooltip('Ordenar'));
      await tester.pumpAndSettle();
      expect(find.text('Ordem decrescente'), findsOneWidget);
      await tester.tap(find.text('Ordem decrescente'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(provider.sortAscending, isFalse);
      expect(
        tester.getTopLeft(find.text('A')).dy,
        lessThan(tester.getTopLeft(find.text('B')).dy),
      );

      // Persistência nas preferências injetadas.
      expect(settings.sortKey, SongSortKey.duration);
      expect(settings.sortAscending, isFalse);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_sort_key'), 'duration');
      expect(prefs.getBool('library_sort_ascending'), isFalse);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
