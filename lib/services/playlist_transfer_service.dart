import 'dart:convert';

import '../models/song_model.dart';
import '../utils/text_normalize.dart';

/// Item 4.5 — transferência de playlists: export em JSON e .m3u8,
/// import com casamento por `filePath` e, na falta, por título+artista
/// normalizados (caixa e acento não atrapalham).
///
/// Tudo aqui é puro (texto ↔ dados): a UI cola no compartilhador e no
/// seletor de arquivos, o provider aplica o resultado no banco — os
/// testes de ida-e-volta rodam sem canais nem sqflite.

/// Uma faixa como aparece no arquivo exportado.
class PlaylistTransferEntry {
  final String title;
  final String? artist;
  final String? album;
  final String? filePath;
  final int? durationMs;

  const PlaylistTransferEntry({
    required this.title,
    this.artist,
    this.album,
    this.filePath,
    this.durationMs,
  });

  /// Do snapshot da playlist: caminho do aparelho; saem pelo caminho do
  /// bundle — o casamento por título+artista cobre quando o arquivo não
  /// existe em outro aparelho.
  factory PlaylistTransferEntry.fromSong(Song song) => PlaylistTransferEntry(
    title: song.title,
    artist: song.artist,
    album: song.album,
    filePath: song.filePath ?? song.assetPath,
    durationMs: song.duration?.inMilliseconds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'artist': artist,
    'album': album,
    'filePath': filePath,
    'durationMs': durationMs,
  };

  factory PlaylistTransferEntry.fromJson(Map<String, Object?> json) {
    final Object? title = json['title'];
    if (title is! String || title.trim().isEmpty) {
      throw const FormatException('Faixa sem título no JSON.');
    }
    return PlaylistTransferEntry(
      title: title,
      artist: json['artist'] is String ? json['artist'] as String : null,
      album: json['album'] is String ? json['album'] as String : null,
      filePath: json['filePath'] is String ? json['filePath'] as String : null,
      durationMs: json['durationMs'] is int ? json['durationMs'] as int : null,
    );
  }
}

/// Arquivo exportado (ou lido na importação).
class PlaylistTransferFile {
  final String name;
  final List<PlaylistTransferEntry> entries;

  const PlaylistTransferFile({required this.name, required this.entries});
}

/// Resultado de uma importação: quantas ENTRARAM e quantas não acharam
/// nada no catálogo ("X importadas, Y não encontradas").
class PlaylistImportReport {
  final int imported;
  final int notFound;

  const PlaylistImportReport({required this.imported, required this.notFound});
}

// ---------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------

/// JSON: `{name, songs: [{title, artist, album, filePath, durationMs}]}`.
String encodePlaylistJson(String name, List<PlaylistTransferEntry> entries) {
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'name': name,
    'songs': <Object?>[for (final entry in entries) entry.toJson()],
  });
}

PlaylistTransferFile decodePlaylistJson(String content) {
  final Object? data = jsonDecode(content);
  if (data is! Map) {
    throw const FormatException('Esperava um objeto JSON de playlist.');
  }
  final Object? name = data['name'];
  final Object? songs = data['songs'];
  if (name is! String || songs is! List) {
    throw const FormatException('JSON sem "name" ou "songs".');
  }
  return PlaylistTransferFile(
    name: name,
    entries: <PlaylistTransferEntry>[
      for (final Object? song in songs)
        if (song is! Map)
          throw const FormatException('Item de "songs" não é objeto.')
        else
          PlaylistTransferEntry.fromJson(Map<String, Object?>.from(song)),
    ],
  );
}

// ---------------------------------------------------------------------
// .m3u8
// ---------------------------------------------------------------------

/// .m3u8: `#EXTINF:{segundos},{artista} - {titulo}` + caminho.
///
/// Faixa sem `filePath` não tem como viajar num m3u8 — sai do arquivo
/// (o JSON, com todos os campos, é o formato completo).
String encodePlaylistM3u8(List<PlaylistTransferEntry> entries) {
  final StringBuffer buffer = StringBuffer('#EXTM3U\n');
  for (final entry in entries) {
    final String? path = entry.filePath;
    if (path == null || path.isEmpty) continue;
    final int seconds = ((entry.durationMs ?? 0) / 1000).round();
    final String label = (entry.artist == null || entry.artist!.isEmpty)
        ? entry.title
        : '${entry.artist} - ${entry.title}';
    buffer
      ..writeln('#EXTINF:$seconds,$label')
      ..writeln(path);
  }
  return buffer.toString();
}

PlaylistTransferFile decodePlaylistM3u8(String content, {String name = ''}) {
  final List<PlaylistTransferEntry> entries = <PlaylistTransferEntry>[];
  String? artist;
  String? title;
  int? seconds;
  for (final String rawLine in const LineSplitter().convert(content)) {
    final String line = rawLine.trim();
    if (line.startsWith('#EXTINF:')) {
      final String rest = line.substring('#EXTINF:'.length);
      final int comma = rest.indexOf(',');
      seconds = comma >= 0 ? int.tryParse(rest.substring(0, comma)) : null;
      final String text = comma >= 0 ? rest.substring(comma + 1) : rest;
      // "Artista - Título": separa na PRIMEIRA ocorrência (o título
      // pode trazer ' - '; o artista, em regra, não).
      final int split = text.indexOf(' - ');
      if (split >= 0) {
        artist = text.substring(0, split);
        title = text.substring(split + 3);
      } else {
        artist = null;
        title = text;
      }
    } else if (line.isEmpty || line.startsWith('#')) {
      continue;
    } else if (title != null) {
      entries.add(
        PlaylistTransferEntry(
          title: title,
          artist: artist,
          filePath: line,
          durationMs: seconds == null ? null : seconds * 1000,
        ),
      );
      artist = null;
      title = null;
      seconds = null;
    }
  }
  return PlaylistTransferFile(name: name, entries: entries);
}

// ---------------------------------------------------------------------
// Casamento com o catálogo
// ---------------------------------------------------------------------

/// Casa as entradas do arquivo com o catálogo: primeiro por `filePath`
/// (igualdade direta), depois por título+artista normalizados (caixa e
/// acento não atrapalham).
///
/// Cada Song atende UMA entrada — importar duas cópias da mesma faixa
/// não aponta duas vezes para o mesmo arquivo.
({List<Song> songs, int notFound}) matchPlaylistEntries(
  List<PlaylistTransferEntry> entries,
  List<Song> catalog,
) {
  final List<bool> songTaken = List<bool>.filled(catalog.length, false);
  final List<bool> entryMatched = List<bool>.filled(entries.length, false);
  final List<Song> matched = <Song>[];

  // Passo 1 — filePath: caminho é identidade de arquivo de verdade.
  final Map<String, int> byPath = <String, int>{};
  for (int i = 0; i < catalog.length; i++) {
    final String? path = catalog[i].filePath ?? catalog[i].assetPath;
    if (path != null && path.isNotEmpty) {
      byPath.putIfAbsent(path, () => i);
    }
  }
  for (int e = 0; e < entries.length; e++) {
    final String? path = entries[e].filePath;
    if (path == null || path.isEmpty) continue;
    final int? index = byPath[path];
    if (index == null || songTaken[index]) continue;
    songTaken[index] = true;
    entryMatched[e] = true;
    matched.add(catalog[index]);
  }

  // Passo 2 — título + artista normalizados, por FILA (duas entradas
  // iguais consomem dois arquivos iguais, se existirem).
  final Map<(String, String), List<int>> byTitleArtist =
      <(String, String), List<int>>{};
  for (int i = 0; i < catalog.length; i++) {
    if (songTaken[i]) continue;
    final (String, String) key = (
      normalizeKey(catalog[i].title),
      normalizeKey(catalog[i].artist ?? ''),
    );
    byTitleArtist.putIfAbsent(key, () => <int>[]).add(i);
  }
  for (int e = 0; e < entries.length; e++) {
    if (entryMatched[e]) continue;
    final (String, String) key = (
      normalizeKey(entries[e].title),
      normalizeKey(entries[e].artist ?? ''),
    );
    final List<int>? queue = byTitleArtist[key];
    if (queue == null || queue.isEmpty) continue;
    final int index = queue.removeAt(0);
    if (songTaken[index]) continue;
    songTaken[index] = true;
    entryMatched[e] = true;
    matched.add(catalog[index]);
  }

  return (songs: matched, notFound: entries.length - matched.length);
}
