// Testes unitários do modelo Song e do tema — lógica pura, sem plugins
// nativos (audioplayers/on_audio_query/permission_handler exigem mocks de
// platform channel, fora do escopo destes testes).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/gallery_image_model.dart';
import 'package:audify/models/pdf_file_model.dart';
import 'package:audify/models/song_model.dart';
import 'package:audify/models/video_model.dart';
import 'package:audify/theme/app_theme.dart';
import 'package:audify/utils/format.dart';

void main() {
  group('Song (asset)', () {
    test('deriva o titulo legivel do nome do arquivo', () {
      final song = Song.fromAsset(assetPath: 'assets/songs/minha_faixa.mp3');
      expect(song.title, 'Minha Faixa');
      expect(song.assetKey, 'songs/minha_faixa.mp3');
      expect(song.isAsset, isTrue);
    });

    test('normaliza hifens e underscores no titulo', () {
      final song =
          Song.fromAsset(assetPath: 'assets/songs/rock_clasico-ao-vivo.mp3');
      expect(song.title, 'Rock Clasico Ao Vivo');
    });

    test('artista desconhecido tem fallback amigavel', () {
      final song = Song.fromAsset(assetPath: 'assets/songs/faixa.mp3');
      expect(song.duration, isNull);
      expect(song.displayArtist, 'Artista desconhecido');
    });

    test('igualdade baseada no id (asset path)', () {
      final a = Song.fromAsset(assetPath: 'assets/songs/x.mp3');
      final b = Song.fromAsset(assetPath: 'assets/songs/x.mp3');
      final c = Song.fromAsset(assetPath: 'assets/songs/y.mp3');
      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('Song (banco de playlists)', () {
    test('roundtrip toStored/fromStored preserva os campos', () {
      final song = Song.fromAsset(assetPath: 'assets/songs/faixa.mp3');
      final stored = song.toStored();
      final restored = Song.fromStored(stored);
      expect(restored, song);
      expect(restored!.title, 'Faixa');
      expect(restored.isAsset, isTrue);
      expect(restored.assetKey, 'songs/faixa.mp3');
    });

    test('fromStored aceita registro sem artist (playlist legada)', () {
      final song = Song.fromStored({
        'song_id': 'media-42',
        'title': 'Sem artista',
        'is_asset': 0,
      });
      expect(song!.displayArtist, 'Artista desconhecido');
      expect(song.mediaId, isNull);
    });
  });

  group('Video', () {
    test('converte map do canal nativo', () {
      final video = Video.fromChannel({
        'id': 7,
        'title': 'Meu vídeo',
        'displayName': 'meu_video.mp4',
        'duration': 65000,
        'path': '/storage/emulated/0/Movies/meu_video.mp4',
        'size': 1048576,
        'dateAdded': 1700000000,
      });
      expect(video.id, 7);
      expect(video.displayTitle, 'Meu vídeo');
      expect(video.duration, const Duration(seconds: 65));
    });

    test('titulo vazio cai para nome do arquivo', () {
      final video = Video.fromChannel({
        'id': 1,
        'title': '',
        'displayName': 'viagem_familia.mp4',
        'duration': 0,
        'path': '/x/viagem_familia.mp4',
        'size': 0,
        'dateAdded': 0,
      });
      expect(video.displayTitle, 'viagem_familia');
    });
  });

  group('GalleryImage', () {
    test('converte map do canal nativo', () {
      final image = GalleryImage.fromChannel({
        'id': 42,
        'name': 'IMG_20240101.jpg',
        'path': '/storage/emulated/0/DCIM/IMG_20240101.jpg',
        'size': 2048000,
        'dateAdded': 1700000000,
        'width': 4000,
        'height': 3000,
      });
      expect(image.id, 42);
      expect(image.name, 'IMG_20240101.jpg');
      expect(image.displayDimensions, '4000 x 3000');
    });

    test('dimensoes desconhecidas nao quebram a exibicao', () {
      final image = GalleryImage.fromChannel({
        'id': 1,
        'name': 'foto.png',
        'path': '/x/foto.png',
        'size': 100,
        'dateAdded': 0,
        'width': -1,
        'height': -1,
      });
      expect(image.displayDimensions, '');
    });
  });

  group('PdfFile', () {
    test('converte map do canal nativo', () {
      final pdf = PdfFile.fromChannel({
        'id': 9,
        'name': 'manual.pdf',
        'path': '/storage/emulated/0/Download/manual.pdf',
        'size': 2621440,
        'dateAdded': 1700000000,
      });
      expect(pdf.id, 'pdf-9');
      expect(pdf.displaySize, '2.5 MB');
    });

    test('seletor SAF cria arquivo de sessao', () {
      final pdf = PdfFile.fromPicked(
        path: '/cache/manual.pdf',
        name: 'manual.pdf',
      );
      expect(pdf.id, 'picked-/cache/manual.pdf');
      expect(pdf.displaySize, '');
    });
  });

  group('formatDuration', () {
    test('mm:ss para durações abaixo de 1h', () {
      expect(formatDuration(const Duration(seconds: 65)), '01:05');
    });

    test('h:mm:ss para durações acima de 1h', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });

  group('AppTheme', () {
    test('usa Material 3 com paleta derivada da cor-semente', () {
      final theme = AppTheme.light;
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.primary, isNotNull);
    });

    test('tema escuro pronto com brightness dark', () {
      final theme = AppTheme.dark;
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, isNotNull);
    });
  });
}