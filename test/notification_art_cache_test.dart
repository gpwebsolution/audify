// Testes do item 1.8: gerador de caminho/chave da capa da notificação.
//
// As funções puras (artKeyFor/uriFromPath) são o contrato: chave estável
// por álbum, logo para assets, null quando não há id, formato file://.
// A gravação em disco usa o ThumbnailDiskCache (path_provider) — em VM
// não há canal nativo, então uriFor é exercitado no caminho em que ele
// falha graciosamente (devolve null, nunca lança).

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/services/notification_art_cache.dart';
import 'package:on_audio_query/on_audio_query.dart';

Song _deviceSong({int? albumId, int? mediaId}) => Song.fromMediaStore(
  SongModel(<dynamic, dynamic>{
    '_id': mediaId ?? 7,
    '_data': '/storage/emulated/0/Music/f.mp3',
    '_display_name': 'f.mp3',
    '_display_name_wo_ext': 'f',
    'title': 'Faixa',
    'artist': 'Artista',
    'album': 'Album',
    'duration': 1000,
    'artist_id': 1,
    'album_id': albumId,
    'album_key': 'k',
    'is_music': 1,
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationArtCache.artKeyFor (pura)', () {
    test('faixa de device usa o id do ÁLBUM (uma capa por álbum)', () {
      expect(
        NotificationArtCache.artKeyFor(_deviceSong(albumId: 42, mediaId: 9)),
        'art_album_42',
      );
    });

    test('sem álbum, cai para o id da faixa', () {
      expect(
        NotificationArtCache.artKeyFor(_deviceSong(albumId: null, mediaId: 9)),
        'art_album_9',
      );
    });

    test('sem álbum nem faixa, não há o que gravar', () {
      // Song reconstruído de banco antigo sem ids de MediaStore — é o
      // único caminho real de chegar sem albumId/mediaId.
      final Song song = Song.fromStored(<String, Object?>{
        'song_id': 'media-9',
        'title': 'X',
        'is_asset': 0,
      })!;
      expect(NotificationArtCache.artKeyFor(song), isNull);
    });

    test('faixa de asset usa a chave da logo do app', () {
      expect(
        NotificationArtCache.artKeyFor(
          Song.fromAsset(assetPath: 'assets/songs/x.mp3'),
        ),
        'art_logo',
      );
    });

    test(
      'chaves de faixas do mesmo álbum são idênticas (cache compartilhado)',
      () {
        final String a = NotificationArtCache.artKeyFor(
          _deviceSong(albumId: 5, mediaId: 1),
        )!;
        final String b = NotificationArtCache.artKeyFor(
          _deviceSong(albumId: 5, mediaId: 2),
        )!;
        expect(a, b);
      },
    );
  });

  group('NotificationArtCache.uriFromPath (pura)', () {
    test('gera Uri file:// absoluto', () {
      final Uri uri = NotificationArtCache.uriFromPath(
        '/data/user/0/app/cache/art_album_5.jpg',
      );
      expect(uri.scheme, 'file');
      expect(uri.path, '/data/user/0/app/cache/art_album_5.jpg');
      expect(uri.toString(), startsWith('file:///'));
    });
  });

  group('NotificationArtCache.uriFor (tolerância a falhas)', () {
    test('sem id de álbum/faixa devolve null sem lançar', () async {
      final Song song = Song.fromStored(<String, Object?>{
        'song_id': 'media-9',
        'title': 'X',
        'is_asset': 0,
      })!;
      final Uri? uri = await NotificationArtCache.uriFor(song);
      expect(uri, isNull);
    });

    test(
      'sem canal nativo (path_provider) não lança e degrada pra null',
      () async {
        // Caminho da logo (asset): os bytes vêm do bundle (funciona em
        // teste), mas o ThumbnailDiskCache não tem canal nativo em VM —
        // a gravação falha graciosamente e uriFor devolve null. Capa é
        // enfeite, não requisito: nunca exceção para cima.
        final Uri? uri = await NotificationArtCache.uriFor(
          Song.fromAsset(assetPath: 'assets/songs/x.mp3'),
        );
        expect(uri, isNull);
      },
    );
  });
}
