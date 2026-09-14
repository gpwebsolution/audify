import 'package:flutter_test/flutter_test.dart';
import 'package:audify/models/image_album.dart';

void main() {
  group('ImageAlbum.fromChannel', () {
    test('reconstrói o mapa do canal nativo', () {
      final album = ImageAlbum.fromChannel({
        'id': 42,
        'name': 'DCIM/Camera',
        'count': 12,
        'coverId': 7,
      });

      expect(album.id, 42);
      expect(album.name, 'DCIM/Camera');
      expect(album.count, 12);
      expect(album.coverId, 7);
      expect(album.displayName, 'Camera');
    });

    test('usa fallbacks quando campos faltam', () {
      final album = ImageAlbum.fromChannel({'id': 1});
      expect(album.name, 'Álbum');
      expect(album.count, 0);
      expect(album.coverId, 0);
      expect(album.displayName, 'Álbum');
    });

    test('displayName de caminho simples retorna o próprio nome', () {
      final album = ImageAlbum.fromChannel(
          {'id': 1, 'name': 'WhatsApp', 'count': 3, 'coverId': 1});
      expect(album.displayName, 'WhatsApp');
    });
  });
}