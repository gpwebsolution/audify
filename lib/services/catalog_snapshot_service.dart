import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song_model.dart';

/// Snapshot leve do catálogo de músicas (item 2.4).
///
/// Guarda a lista PRONTA em JSON (mesmos campos de [Song.toStored]) para
/// o boot mostrar a biblioteca na hora, enquanto a varredura real do
/// MediaStore roda em segundo plano e reconcilia.
///
/// Toda falha degrada para `null`/silêncio (sem path_provider — ex. testes
/// em VM, disco cheio, JSON corrompido, formato de versão antiga): o
/// chamador cai no carregamento completo. O snapshot nunca é obrigatório.
class CatalogSnapshotService {
  /// Diretório injetável (testes usam uma pasta temporária de verdade;
  /// o padrão é o documents do app via path_provider).
  CatalogSnapshotService({this.directory});

  /// Versão do formato — arquivo gravado por outra versão do app é
  /// ignorado e o catálogo é reconstruído do zero.
  static const int formatVersion = 1;

  static const String fileName = 'music_catalog_snapshot.json';

  final Future<Directory?> Function()? directory;

  Future<File?> _snapshotFile() async {
    try {
      // Copia para local: campo público não promove a não-nulo.
      final Future<Directory?> Function()? resolve = directory;
      final Directory? dir = resolve != null
          ? await resolve()
          : await getApplicationDocumentsDirectory();
      if (dir == null) return null;
      return File('${dir.path}/$fileName');
    } catch (e) {
      // path_provider sem canal nativo (teste em VM) ou sem diretório:
      // degrada para "sem snapshot".
      debugPrint('[CatalogSnapshot] sem diretório ($e) — sem snapshot');
      return null;
    }
  }

  /// Lê o snapshot. `null` = sem snapshot utilizável (primeira execução,
  /// arquivo ausente, JSON corrompido ou versão incompatível).
  Future<List<Song>?> load() async {
    try {
      final File? file = await _snapshotFile();
      if (file == null || !await file.exists()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['version'] != formatVersion) return null;
      final Object? rawSongs = decoded['songs'];
      if (rawSongs is! List<Object?>) return null;
      final List<Song> songs = <Song>[];
      for (final Object? raw in rawSongs) {
        if (raw is! Map<String, Object?>) continue;
        final Song? song = Song.fromStored(raw);
        if (song != null) songs.add(song);
      }
      // Lista vazia não adianta: o caminho frio faz a mesma coisa.
      return songs.isEmpty ? null : songs;
    } catch (e) {
      // Corrompido/ilegível: descarta e deixa o próximo save sobrescrever.
      debugPrint('[CatalogSnapshot] load falhou ($e) — re-escaneia do zero');
      return null;
    }
  }

  /// Grava o snapshot de forma ATÔMICA (tmp + rename): se o app morrer no
  /// meio do write, sobra o arquivo anterior intacto, nunca meio JSON.
  Future<void> save(List<Song> songs) async {
    try {
      final File? file = await _snapshotFile();
      if (file == null) return;
      final String payload = jsonEncode(<String, Object?>{
        'version': formatVersion,
        'songs': <Map<String, Object?>>[for (final Song s in songs) s.toStored()],
      });
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      // Snapshot é conforto, não dado crítico: falha de escrita não
      // pode afetar o app.
      debugPrint('[CatalogSnapshot] save falhou (ignorado): $e');
    }
  }
}
