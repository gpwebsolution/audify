import 'dart:io';
import 'dart:typed_data';

import 'package:audify/models/file_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audify/services/file_query_service.dart';

/// Testes do FileQueryService em dart:io puro — rodam no host sem canal
/// nativo (as funções testadas não tocam MethodChannel).
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audify_file_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File mkFile(String name, String content) {
    final File f = File('${temp.path}/$name');
    f.parent.createSync(recursive: true);
    return f..writeAsStringSync(content);
  }

  group('listDirectory', () {
    test('pagina, ordena pastas primeiro e respeita includeHidden', () async {
      Directory('${temp.path}/sub').createSync();
      mkFile('a.txt', 'a');
      mkFile('b.mp3', 'bb');
      mkFile('.oculto', 'x');

      final FileListResult page1 = await FileQueryService.listDirectory(
        path: temp.path,
        offset: 0,
        limit: 2,
        sortBy: 'name',
        sortAscending: true,
        includeHidden: false,
      );

      expect(
        page1.items.first.isDirectory,
        isTrue,
        reason: 'pastas sempre primeiro',
      );
      expect(page1.hasMore, isTrue);
      expect(page1.items.any((i) => i.name == '.oculto'), isFalse);

      final FileListResult all = await FileQueryService.listDirectory(
        path: temp.path,
        offset: 0,
        limit: 100,
        sortBy: 'name',
        sortAscending: true,
        includeHidden: true,
      );
      expect(all.items.length, 4);
      expect(all.hasMore, isFalse);
    });

    test('filtra por tipo de arquivo', () async {
      mkFile('musica.mp3', 'x');
      mkFile('foto.jpg', 'y');

      final FileListResult result = await FileQueryService.listDirectory(
        path: temp.path,
        offset: 0,
        limit: 100,
        sortBy: 'name',
        sortAscending: true,
        filterType: FileType.audio,
      );
      expect(result.items.map((i) => i.name), ['musica.mp3']);
    });
  });

  group('searchFiles', () {
    test('busca recursiva case-insensitive', () async {
      Directory('${temp.path}/nível1/nível2').createSync(recursive: true);
      mkFile('nível1/RelatórioFinal.PDF', 'pdf');
      mkFile('outra.txt', 'txt');

      final results = await FileQueryService.searchFiles(
        query: 'relatório',
        rootPath: temp.path,
      );
      expect(results, hasLength(1));
      expect(results.first.extension, 'pdf');
    });
  });

  group('operações de arquivo', () {
    test('copy/move/rename/delete com sufixo único', () async {
      final File src = mkFile('orig.txt', 'conteudo');

      // copy com destino existente -> " (1)"
      final bool copied = await FileQueryService.copy(
        sourcePath: src.path,
        destPath: '${temp.path}/destino.txt',
      );
      expect(copied, isTrue);
      expect(File('${temp.path}/destino.txt').existsSync(), isTrue);

      final bool renamed = await FileQueryService.rename(
        path: '${temp.path}/destino.txt',
        newName: 'renomeado.txt',
      );
      expect(renamed, isTrue);
      expect(File('${temp.path}/renomeado.txt').existsSync(), isTrue);
      expect(File('${temp.path}/destino.txt').existsSync(), isFalse);

      final bool moved = await FileQueryService.move(
        sourcePath: '${temp.path}/renomeado.txt',
        destPath: '${temp.path}/sub/movido.txt',
      );
      expect(moved, isTrue);
      expect(
        File('${temp.path}/sub/movido.txt').readAsStringSync(),
        'conteudo',
      );

      final bool deleted = await FileQueryService.delete(
        path: src.path,
        useTrash: false,
      );
      expect(deleted, isTrue);
      expect(src.existsSync(), isFalse);
    });

    test('createDirectory aninhada', () async {
      final bool ok = await FileQueryService.createDirectory(
        '${temp.path}/a/b/c',
      );
      expect(ok, isTrue);
      expect(Directory('${temp.path}/a/b/c').existsSync(), isTrue);
    });
  });

  group('zip', () {
    test('cria e extrai zip idempotente', () async {
      mkFile('pasta/dentro.txt', 'zip me');

      final String zipPath = '${temp.path}/pacote.zip';
      final bool zipped = await FileQueryService.createZip(
        sourcePaths: ['${temp.path}/pasta'],
        zipPath: zipPath,
      );
      expect(zipped, isTrue);
      expect(File(zipPath).lengthSync(), greaterThan(0));

      final String dest = '${temp.path}/extraido';
      final bool extracted = await FileQueryService.extractArchive(
        archivePath: zipPath,
        destPath: dest,
      );
      expect(extracted, isTrue);
      // O serviço extrai para uma subpasta oculta ".<nome>_extracted".
      expect(
        File('$dest/.pacote.zip_extracted/pasta/dentro.txt').readAsStringSync(),
        'zip me',
      );
    });
  });

  group('getFileDetails', () {
    test('retorna tamanho/datas/permissões', () async {
      final File f = mkFile('detalhe.txt', 'abc');
      final details = await FileQueryService.getFileDetails(f.path);
      expect(details, isNotNull);
      expect(details!.size, 3);
      expect(details.permissions, isNotEmpty);
      expect(details.exifData, isNull, reason: 'txt não tem EXIF');
    });
  });

  group('findDuplicates', () {
    test('agrupa por conteúdo idêntico via hash', () async {
      mkFile('x/a.bin', 'MESMO-CONTEUDO');
      mkFile('x/b.bin', 'MESMO-CONTEUDO');
      mkFile('x/c.bin', 'diferente');

      final groups = await FileQueryService.findDuplicates(
        rootPath: temp.path,
        minSize: 1,
      );
      expect(groups, hasLength(1));
      expect(groups.first.files.length, 2);
    });
  });

  group('getStorageUsage / getLargestFiles', () {
    test('soma tamanhos e lista maiores primeiro', () async {
      mkFile('pequeno.txt', '12345'); // 5 bytes
      mkFile('grande.txt', '1' * 1000);

      final usage = await FileQueryService.getStorageUsage(rootPath: temp.path);
      expect(usage.byCategory.isNotEmpty, isTrue);

      final largest = await FileQueryService.getLargestFiles(
        limit: 10,
        rootPath: temp.path,
      );
      expect(largest, isNotEmpty);
      expect(largest.first.name, 'grande.txt');
    });
  });

  // ===========================================================================
  // ApkInfo — o ícone do app vem do nativo em PNG.
  // ===========================================================================
  group('ApkInfo.fromChannel', () {
    test('lê o ícone em PNG', () {
      final Uint8List png = Uint8List.fromList(<int>[137, 80, 78, 71]);
      final ApkInfo info = ApkInfo.fromChannel(<dynamic, dynamic>{
        'packageName': 'com.exemplo.app',
        'versionName': '1.2.3',
        'versionCode': 45,
        'appName': 'Exemplo',
        'minSdkVersion': 24,
        'targetSdkVersion': 35,
        'icon': png,
      });

      expect(info.icon, isNotNull);
      expect(info.icon!.length, 4);
      expect(info.appName, 'Exemplo');
      expect(info.versionCode, 45);
    });

    test('ícone ausente não quebra: a UI usa o ícone genérico', () {
      final ApkInfo info = ApkInfo.fromChannel(<dynamic, dynamic>{
        'packageName': 'com.exemplo.app',
        'versionName': '1.0',
        'versionCode': 1,
        'appName': 'Exemplo',
        'minSdkVersion': 24,
        'targetSdkVersion': 35,
      });

      expect(info.icon, isNull);
    });

    test('ícone de tipo inesperado é ignorado, sem lançar', () {
      final ApkInfo info = ApkInfo.fromChannel(<dynamic, dynamic>{
        'packageName': 'p',
        'versionName': '1',
        'versionCode': 1,
        'appName': 'a',
        'minSdkVersion': 24,
        'targetSdkVersion': 35,
        // O SO pode mandar algo inesperado; preferimos o ícone genérico a
        // estourar um cast na tela.
        'icon': 'não sou bytes',
      });

      expect(info.icon, isNull);
    });

    test('metadados ausentes caem em valores seguros', () {
      final ApkInfo info = ApkInfo.fromChannel(<dynamic, dynamic>{});
      expect(info.packageName, '?');
      expect(info.versionName, '?');
      expect(info.versionCode, 0);
      expect(info.icon, isNull);
    });
  });
}
