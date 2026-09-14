import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audify/services/pdf_progress_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PdfProgressService', () {
    test('salva e recupera a última página por arquivo', () async {
      await PdfProgressService.saveLastPage('/a/b/doc.pdf', 7);
      expect(await PdfProgressService.loadLastPage('/a/b/doc.pdf'), 7);
    });

    test('não salva página 1 (estado inicial implícito)', () async {
      await PdfProgressService.saveLastPage('/a/b/doc.pdf', 1);
      expect(await PdfProgressService.loadLastPage('/a/b/doc.pdf'), 1);
    });

    test('chaves independentes por arquivo', () async {
      await PdfProgressService.saveLastPage('/a/b/one.pdf', 3);
      await PdfProgressService.saveLastPage('/a/b/two.pdf', 9);
      expect(await PdfProgressService.loadLastPage('/a/b/one.pdf'), 3);
      expect(await PdfProgressService.loadLastPage('/a/b/two.pdf'), 9);
    });

    test('clear remove o progresso', () async {
      await PdfProgressService.saveLastPage('/a/b/doc.pdf', 5);
      await PdfProgressService.clear('/a/b/doc.pdf');
      expect(await PdfProgressService.loadLastPage('/a/b/doc.pdf'), 1);
    });

    test('arquivo nunca lido retorna 1', () async {
      expect(await PdfProgressService.loadLastPage('/x/y/novo.pdf'), 1);
    });
  });
}