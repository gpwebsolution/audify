// Testes do item 4.4 — seletor de playlist com "Nova playlist" embutida.
//
// Três camadas:
//  - seletor vazio: cria no lugar (dialog de nome) e a recém-criada já
//    sai como a ESCOLHIDA — ninguém troca de aba;
//  - seletor com lista: mostra contagens e escolhe na hora;
//  - nome duplicado: avisa e NÃO entrega playlist;
//  - wire-up: menu ⋮ da tela Música → "Adicionar à playlist" → seletor
//    → cria → faixa entra e o aviso "Adicionada a ..." aparece.
//
// Persistência em duplo fake (PlaylistRepository sobrescrito): nenhum
// teste deste arquivo toca o sqflite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/playlist_provider.dart';
import 'package:audify/repositories/playlist_repository.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/widgets/playlist_picker_sheet.dart';
import 'package:audify/widgets/song_list_tile.dart';

import 'support/playable_audio_service.dart';

class _FakePlaylistRepository extends PlaylistRepository {
  final Map<int, String> names = <int, String>{};
  final Map<int, int> songCounts = <int, int>{};
  final List<({int playlistId, Song song})> added =
      <({int playlistId, Song song})>[];
  int _nextId = 1;

  void seed(String name, {int songCount = 0}) {
    names[_nextId] = name;
    songCounts[_nextId] = songCount;
    _nextId++;
  }

  @override
  Future<List<Map<String, Object?>>> getPlaylists() async =>
      <Map<String, Object?>>[
        for (final MapEntry<int, String> entry in names.entries)
          <String, Object?>{
            'id': entry.key,
            'name': entry.value,
            'song_count': songCounts[entry.key] ?? 0,
            'video_count': 0,
          },
      ];

  @override
  Future<void> createPlaylist(String name) async {
    if (names.containsValue(name)) {
      throw Exception('UNIQUE constraint failed: playlists.name');
    }
    names[_nextId] = name;
    songCounts[_nextId] = 0;
    _nextId++;
  }

  @override
  Future<void> addSong(int playlistId, Song song) async {
    added.add((playlistId: playlistId, song: song));
    songCounts[playlistId] = (songCounts[playlistId] ?? 0) + 1;
  }
}

class _FakeSongRepository extends SongRepository {
  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => <Song>[
        Song.fromAsset(assetPath: 'assets/songs/alpha.mp3'),
      ];
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

String _subtitles(Playlist playlist) => '${playlist.songCount} faixas';

/// Host mínimo do seletor: um botão que abre a folha e registra o que
/// [showPlaylistPickerSheet] entregou em [picks].
Widget _host(PlaylistProvider playlists, List<Playlist> picks) =>
    ChangeNotifierProvider<PlaylistProvider>.value(
      value: playlists,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                key: const Key('abrir-seletor'),
                onPressed: () => showPlaylistPickerSheet(
                  context,
                  onPick: (Playlist playlist) async => picks.add(playlist),
                  subtitleOf: _subtitles,
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('seletor "Nova playlist" (4.4)', () {
    testWidgets('vazio: cria no lugar e entrega a nova playlist',
        (WidgetTester tester) async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository();
      final PlayerProvider player =
          PlayerProvider(PlayableAudioService());
      addTearDown(player.dispose);
      final PlaylistProvider playlists = PlaylistProvider(
        player,
        repository: repo,
      );
      addTearDown(playlists.dispose);
      final List<Playlist> picks = <Playlist>[];

      await tester.pumpWidget(_host(playlists, picks));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('abrir-seletor')));
      await tester.pumpAndSettle();
      // Sem nenhuma criada: só a entrada de criar aparece.
      expect(find.text('Nova playlist'), findsOneWidget);
      expect(find.text('Cria e escolhe em seguida'), findsOneWidget);

      await tester.tap(find.text('Nova playlist'));
      await tester.pumpAndSettle();
      // Dialog de nome no lugar (mesmo formato do FAB da aba Playlists).
      await tester.enterText(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ), 'Viagens');
      await tester.tap(find.text('Criar'));
      await tester.pumpAndSettle();

      expect(picks, hasLength(1));
      expect(picks.single.name, 'Viagens');
      expect(
        playlists.playlists.map((Playlist p) => p.name),
        contains('Viagens'),
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('com lista: mostra contagens e escolhe na hora',
        (WidgetTester tester) async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository()
        ..seed('Trilha', songCount: 3)
        ..seed('Festa');
      final PlayerProvider player =
          PlayerProvider(PlayableAudioService());
      addTearDown(player.dispose);
      final PlaylistProvider playlists = PlaylistProvider(
        player,
        repository: repo,
      );
      addTearDown(playlists.dispose);
      final List<Playlist> picks = <Playlist>[];

      await tester.pumpWidget(_host(playlists, picks));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('abrir-seletor')));
      await tester.pumpAndSettle();
      expect(find.text('Nova playlist'), findsOneWidget);
      expect(find.text('Trilha'), findsOneWidget);
      expect(find.text('3 faixas'), findsOneWidget);
      expect(find.text('Festa'), findsOneWidget);
      expect(find.text('0 faixas'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);

      await tester.tap(find.text('Trilha'));
      await tester.pumpAndSettle();
      expect(picks, hasLength(1));
      expect(picks.single.name, 'Trilha');
      // Folha fechou de verdade.
      expect(find.text('Nova playlist'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nome duplicado: avisa e não escolhe nada',
        (WidgetTester tester) async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository()
        ..seed('Viagens');
      final PlayerProvider player =
          PlayerProvider(PlayableAudioService());
      addTearDown(player.dispose);
      final PlaylistProvider playlists = PlaylistProvider(
        player,
        repository: repo,
      );
      addTearDown(playlists.dispose);
      final List<Playlist> picks = <Playlist>[];

      await tester.pumpWidget(_host(playlists, picks));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('abrir-seletor')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nova playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ), 'Viagens');
      await tester.tap(find.text('Criar'));
      await tester.pumpAndSettle();

      expect(picks, isEmpty);
      expect(
        find.text('Já existe uma playlist com o nome "Viagens".'),
        findsOneWidget,
      );
      // Só a original no provider.
      expect(playlists.playlists, hasLength(1));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('wire-up na tela Música (4.4)', () {
    testWidgets(
      'menu ⋮ → Adicionar à playlist → cria e adiciona a faixa',
      (WidgetTester tester) async {
        final PlayerProvider provider = PlayerProvider(
          PlayableAudioService(),
          songRepository: _FakeSongRepository(),
          sessionRepository: _FakeSessionRepository(),
        );
        addTearDown(provider.dispose);
        await provider.init();

        final _FakePlaylistRepository repo = _FakePlaylistRepository()
          ..seed('Trilha');
        final PlaylistProvider playlists = PlaylistProvider(
          provider,
          repository: repo,
        );
        addTearDown(playlists.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChangeNotifierProvider<PlayerProvider>.value(
                value: provider,
                child: ChangeNotifierProvider<PlaylistProvider>.value(
                  value: playlists,
                  child: const MusicScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // ⋮ da faixa → "Adicionar à playlist" (seletor, não outra aba).
        await tester.tap(
          find.descendant(
            of: find.ancestor(
              of: find.text('Alpha'),
              matching: find.byType(SongListTile),
            ),
            matching: find.byTooltip('Ações da faixa'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Adicionar à playlist'));
        await tester.pumpAndSettle();

        expect(find.text('Nova playlist'), findsOneWidget);
        expect(find.text('Trilha'), findsOneWidget);

        await tester.tap(find.text('Nova playlist'));
        await tester.pumpAndSettle();
        await tester.enterText(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ), 'Viagens');
        await tester.tap(find.text('Criar'));
        await tester.pumpAndSettle();

        // A recém-criada recebeu a faixa e o aviso sai na tela chamadora.
        expect(repo.added, hasLength(1));
        // 'Viagens' é a SEGUNDA do fake (a semeada 'Trilha' é a 1).
        expect(repo.names[repo.added.single.playlistId], 'Viagens');
        expect(repo.added.single.song.title, 'Alpha');
        expect(find.text('Adicionada a "Viagens"'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
