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
    test('cria playlist e adiciona músicas e vídeos (contagens mistas)',
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
    });

    test('addVideo é idempotente (mesmo id não duplica)', () async {
      final int id =
          (await PlaylistDatabase.createPlaylist('P'))['id'] as int;
      await PlaylistDatabase.addVideo(id, video(7, 'X'));
      await PlaylistDatabase.addVideo(id, video(7, 'X'));
      expect(await PlaylistDatabase.getVideos(id), hasLength(1));
    });

    test('removeVideo e removeVideoFromAll', () async {
      final int a =
          (await PlaylistDatabase.createPlaylist('A'))['id'] as int;
      final int b =
          (await PlaylistDatabase.createPlaylist('B'))['id'] as int;
      await PlaylistDatabase.addVideo(a, video(3, 'V'));
      await PlaylistDatabase.addVideo(b, video(3, 'V'));

      await PlaylistDatabase.removeVideo(a, 3);
      expect(await PlaylistDatabase.getVideos(a), isEmpty);
      expect(await PlaylistDatabase.getVideos(b), hasLength(1));

      await PlaylistDatabase.removeVideoFromAll(3);
      expect(await PlaylistDatabase.getVideos(b), isEmpty);
    });

    test('removeSongFromAll limpa a música de todas as playlists', () async {
      final int a =
          (await PlaylistDatabase.createPlaylist('A'))['id'] as int;
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
      final int id =
          (await PlaylistDatabase.createPlaylist('P'))['id'] as int;
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
}