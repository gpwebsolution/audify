// Item 3.6 — resolução de letras OFFLINE (sem rede, sem dependência):
//  1. arquivo .lrc com o MESMO nome do áudio na MESMA pasta (para
//     faixas de arquivo) ou no bundle (faixas embutidas) — preferido,
//     porque traz os timestamps da sincronização;
//  2. na falta dele, a letra EMBUTIDA no próprio MP3 (ID3v2 USLT) —
//     texto corrido vira [LrcLyrics.unsynced] (mostrado sem destaque);
//     se o texto embutido já trouxer marcações LRC, sincroniza.
// Falha de IO/tag vira null + log técnico — nunca derruba a UI.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;

import '../models/song_model.dart';
import '../utils/id3_lyrics_reader.dart';
import '../utils/lrc_parser.dart';
import 'error_log_service.dart';

/// Assinatura do carregador (injetável nos testes de UI — ver
/// [LyricsService.debugLoader] e test/lyrics_ui_test.dart).
typedef LyricsLoader = Future<LrcLyrics?> Function(Song song);

class LyricsService {
  LyricsService._();

  /// Cache por arquivo: letras não mudam durante a sessão na prática.
  static final Map<String, LrcLyrics?> _cache = <String, LrcLyrics?>{};

  /// Limpa o cache (testes partem de um estado conhecido).
  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// Duplo para testes de widget: quando definido, [forSong] repassa
  /// para ele (o loader real lê disco/bundle — em ambiente com
  /// FakeAsync isso não resolve; o app usa o caminho normal).
  @visibleForTesting
  static LyricsLoader? debugLoader;

  static Future<LrcLyrics?> forSong(Song song) {
    final LyricsLoader? over = debugLoader;
    if (over != null) return over(song);
    final String key = song.filePath ?? song.assetPath ?? song.id;
    if (_cache.containsKey(key)) return Future<LrcLyrics?>.value(_cache[key]);
    return _load(song).then((LrcLyrics? lyrics) {
      _cache[key] = lyrics;
      return lyrics;
    });
  }

  static Future<LrcLyrics?> _load(Song song) async {
    try {
      final String? sidecar = await _sidecarSource(song);
      if (sidecar != null) {
        final LrcLyrics? parsed = LrcLyrics.parse(sidecar);
        if (parsed != null) return parsed;
        // .lrc existe mas não tem timestamps: tenta a embutida abaixo.
      }
      final String? embedded = await _embeddedSource(song);
      if (embedded == null) return null;
      final LrcLyrics? parsed = LrcLyrics.parse(embedded);
      if (parsed != null) return parsed;
      final String text = embedded.trim();
      return text.isEmpty ? null : LrcLyrics.unsynced(text);
    } catch (e, s) {
      ErrorLogService.logSync('lyrics/load', e, s);
      return null;
    }
  }

  /// .lrc ao lado do áudio: troca só a extensão do caminho.
  static Future<String?> _sidecarSource(Song song) async {
    final String? filePath = song.filePath;
    if (filePath != null) {
      final File file = File(p.setExtension(filePath, '.lrc'));
      if (!await file.exists()) return null;
      return _decode(await file.readAsBytes());
    }
    final String? assetPath = song.assetPath;
    if (assetPath != null) {
      try {
        final ByteData data = await rootBundle.load(
          p.setExtension(assetPath, '.lrc'),
        );
        return _decode(_byteList(data));
      } catch (_) {
        // .lrc não empacotado é o caso COMUM (só o áudio vem no bundle).
        return null;
      }
    }
    return null;
  }

  /// Letra embutida (ID3v2 USLT). Só os primeiros [maxTagBytes] do
  /// arquivo bastam — as tags vivem no início; assets são lidos por
  /// inteiro (empacotados e pequenos por definição).
  static const int maxTagBytes = 256 * 1024;

  static Future<String?> _embeddedSource(Song song) async {
    try {
      final String? filePath = song.filePath;
      if (filePath != null) {
        final File file = File(filePath);
        if (!await file.exists()) return null;
        final RandomAccessFile raf = await file.open();
        try {
          final Uint8List head = await raf.read(maxTagBytes);
          final String? text = readId3v2Usult(head);
          return (text == null || text.trim().isEmpty) ? null : text;
        } finally {
          await raf.close();
        }
      }
      final String? assetPath = song.assetPath;
      if (assetPath != null) {
        final ByteData data = await rootBundle.load(assetPath);
        final String? text = readId3v2Usult(_byteList(data));
        return (text == null || text.trim().isEmpty) ? null : text;
      }
      return null;
    } catch (e, s) {
      ErrorLogService.logSync('lyrics/id3', e, s);
      return null;
    }
  }

  static Uint8List _byteList(ByteData data) => data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

  /// .lrc antigos vêm em latin1; UTF-8 estrito falha e cai nele.
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}
