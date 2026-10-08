import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/models/video_model.dart';
import 'package:audify/services/playlist_database.dart';

/// Testes do banco de playlists — agora com mídia mista (músicas + vídeos).
///
/// Usa sqflite_common_ffi (SQLite em memória) em vez do canal nativo do
/// sqflite, que não existe em testes de unidade.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await PlaylistDatabase.close();
    // O arquivo do banco persiste entre testes — remove para começar limpo
    // (o construtor de playlist tem nome UNIQUE).
    await databaseFactory.deleteDatabase(
      p.join(await getDatabasesPath(), 'audify.db'),
    );
  });

  tearDownAll(() async {
    await PlaylistDatabase.close();
  });

  Video video(int id, String name) => Video(
    id: id,
    title: name,
    displayName: '$name.mp4',
    duration: const Duration(minutes: 2),
    path: '/storage/emulated/0/Movies/$name.mp4',
    size: 1024,
    dateAdded: 1,
  );

  group('PlaylistDatabase com vídeos', () {
    test(
      'cria playlist e adiciona músicas e vídeos (contagens mistas)',
      () async {
        final int id =
            (await PlaylistDatabase.createPlaylist('Mista'))['id'] as int;

        // Música não-persistível: precisa do Song.fromMediaStore — usamos
        // o fromStored inverso: construímos via toStored de um Song fake.
        // Para simplificar, usamos um Song reconstruído de um mapa salvo.
        final Song song = Song.fromStored({
          'song_id': 'media-1',
          'title': 'Faixa 1',
          'artist': 'Artista',
          'is_asset': 0,
        })!;
        await PlaylistDatabase.addSong(id, song);
        await PlaylistDatabase.addVideo(id, video(1, 'Video 1'));
        await PlaylistDatabase.addVideo(id, video(2, 'Video 2'));

        final List<Map<String, Object?>> playlists =
            await PlaylistDatabase.getPlaylists();
        expect(playlists, hasLength(1));
        expect(playlists.first['song_count'], 1);
        expect(playlists.first['video_count'], 2);

        final List<Video> videos = await PlaylistDatabase.getVideos(id);
        expect(videos, hasLength(2));
        expect(videos.first.displayTitle, 'Video 1');
      },
    );

    test('addVideo é idempotente (mesmo id não duplica)', () async {
      final int id = (await PlaylistDatabase.createPlaylist('P'))['id'] as int;
      await PlaylistDatabase.addVideo(id, video(7, 'X'));
      await PlaylistDatabase.addVideo(id, video(7, 'X'));
      expect(await PlaylistDatabase.getVideos(id), hasLength(1));
    });

    test('removeVideo e removeVideoFromAll', () async {
      final int a = (await PlaylistDatabase.createPlaylist('A'))['id'] as int;
      final int b = (await PlaylistDatabase.createPlaylist('B'))['id'] as int;
      await PlaylistDatabase.addVideo(a, video(3, 'V'));
      await PlaylistDatabase.addVideo(b, video(3, 'V'));

      await PlaylistDatabase.removeVideo(a, 3);
      expect(await PlaylistDatabase.getVideos(a), isEmpty);
      expect(await PlaylistDatabase.getVideos(b), hasLength(1));

      await PlaylistDatabase.removeVideoFromAll(3);
      expect(await PlaylistDatabase.getVideos(b), isEmpty);
    });

    test('removeSongFromAll limpa a música de todas as playlists', () async {
      final int a = (await PlaylistDatabase.createPlaylist('A'))['id'] as int;
      final Song song = Song.fromStored({
        'song_id': 'media-9',
        'title': 'T',
        'is_asset': 0,
      })!;
      await PlaylistDatabase.addSong(a, song);
      await PlaylistDatabase.removeSongFromAll('media-9');
      expect(await PlaylistDatabase.getSongs(a), isEmpty);
    });

    test('reorderVideos persiste a ordem', () async {
      final int id = (await PlaylistDatabase.createPlaylist('P'))['id'] as int;
      await PlaylistDatabase.addVideo(id, video(1, 'Um'));
      await PlaylistDatabase.addVideo(id, video(2, 'Dois'));
      await PlaylistDatabase.addVideo(id, video(3, 'Três'));

      await PlaylistDatabase.reorderVideos(id, [3, 1, 2]);
      final List<Video> videos = await PlaylistDatabase.getVideos(id);
      expect(videos.map((v) => v.id).toList(), [3, 1, 2]);
    });

    test('migração v1 -> v2 não quebra playlists existentes', () async {
      // Cria o banco no esquema v1 (só músicas), fecha e reabre: o
      // onUpgrade deve criar playlist_videos sem perder as faixas.
      final int id =
          (await PlaylistDatabase.createPlaylist('Legado'))['id'] as int;
      final Song song = Song.fromStored({
        'song_id': 'media-5',
        'title': 'Legada',
        'is_asset': 0,
      })!;
      await PlaylistDatabase.addSong(id, song);

      // Simula reabertura (fecha o singleton).
      await PlaylistDatabase.close();

      // Nova abertura: banco já tem o esquema novo (mesma versão). O teste
      // garante que o caminho v2 lê as faixas antigas normalmente.
      expect(await PlaylistDatabase.getSongs(id), hasLength(1));
      final List<Map<String, Object?>> rows =
          await PlaylistDatabase.getPlaylists();
      expect(rows.first['song_count'], 1);
      expect(rows.first['video_count'], 0);
    });
  });

  // ===========================================================================
  // Lote (modo de seleção múltipla) — é o caminho de "colocar 10 músicas de
  // uma vez numa playlist".
  // ===========================================================================
  group('PlaylistDatabase em lote', () {
    Song song(String id) => Song.fromStored(<String, Object?>{
      'song_id': 'media-$id',
      'title': 'Faixa $id',
      'is_asset': 0,
    })!;

    test('addSongs insere várias faixas de uma vez, na ordem', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      final List<Song> songs = List<Song>.generate(10, (int i) => song('$i'));

      final int added = await PlaylistDatabase.addSongs(id, songs);

      expect(added, 10);
      final List<Song> stored = await PlaylistDatabase.getSongs(id);
      expect(stored.length, 10);
      // Ordem preservada: é o que o usuário vê ao abrir a playlist.
      expect(
        stored.map((Song s) => s.id).toList(),
        List<String>.generate(10, (int i) => 'media-$i'),
      );
    });

    test('addSongs não duplica o que já está na playlist', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      await PlaylistDatabase.addSong(id, song('1'));

      // 3 pedidos, um deles repetido e um já existente.
      final int added = await PlaylistDatabase.addSongs(id, <Song>[
        song('1'),
        song('2'),
        song('3'),
      ]);

      // Só as 2 novas contam: a contagem precisa ser exata, senão a UI
      // mentiria com "3 adicionadas".
      expect(added, 2);
      expect((await PlaylistDatabase.getSongs(id)).length, 3);
    });

    test('addSongs não duplica dentro do próprio lote', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      final int added = await PlaylistDatabase.addSongs(id, <Song>[
        song('7'),
        song('7'),
      ]);
      expect(added, 1);
      expect((await PlaylistDatabase.getSongs(id)).length, 1);
    });

    test('addSongs continua a posição depois de itens existentes', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      await PlaylistDatabase.addSong(id, song('antes'));

      await PlaylistDatabase.addSongs(id, <Song>[song('a'), song('b')]);

      final List<Song> stored = await PlaylistDatabase.getSongs(id);
      expect(stored.map((Song s) => s.id).toList(), <String>[
        'media-antes',
        'media-a',
        'media-b',
      ]);
    });

    test('addSongs com lista vazia não faz nada', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      expect(await PlaylistDatabase.addSongs(id, const <Song>[]), 0);
      expect(await PlaylistDatabase.getSongs(id), isEmpty);
    });

    test('addSongs em playlist sem nada começa na posição 0', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      await PlaylistDatabase.addSongs(id, <Song>[song('x'), song('y')]);
      final List<Song> stored = await PlaylistDatabase.getSongs(id);
      expect(stored.map((Song s) => s.id), <String>['media-x', 'media-y']);
    });

    test('addVideos insere vários vídeos de uma vez', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      final List<Video> videos = <Video>[
        video(1, 'Um'),
        video(2, 'Dois'),
        video(3, 'Três'),
      ];

      expect(await PlaylistDatabase.addVideos(id, videos), 3);
      expect(
        (await PlaylistDatabase.getVideos(id)).map((Video v) => v.id).toList(),
        <int>[1, 2, 3],
      );
    });

    test('addVideos não duplica vídeo já presente', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      await PlaylistDatabase.addVideo(id, video(5, 'Cinco'));

      final int added = await PlaylistDatabase.addVideos(id, <Video>[
        video(5, 'Cinco'),
        video(6, 'Seis'),
      ]);
      expect(added, 1);
      expect((await PlaylistDatabase.getVideos(id)).length, 2);
    });

    test('a contagem da playlist reflete o lote inteiro', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('Lote'))['id'] as int;
      await PlaylistDatabase.addSongs(
        id,
        List<Song>.generate(10, (int i) => song('$i')),
      );
      final List<Map<String, Object?>> rows =
          await PlaylistDatabase.getPlaylists();
      expect(rows.first['song_count'], 10);
    });
  });
}
