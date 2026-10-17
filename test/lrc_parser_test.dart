// Testes do parser LRC (item 3.6) — ACEITE do item: offsets, múltiplos
// timestamps e linhas sem tempo. Cobre ainda os formatos de fração, a
// ordenação estável, a binária de destaque (indexAt) e o modo texto
// corrido da letra embutida.

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/utils/lrc_parser.dart';

LrcLyrics _parse(String source) => LrcLyrics.parse(source)!;

void main() {
  group('LrcLyrics.parse — aceite 3.6', () {
    test('offset POSITIVO adianta a letra; negativo atrasa', () {
      // Convenção do formato: '+' faz a letra aparecer ANTES.
      final LrcLyrics plus = _parse('[offset:+500]\n[00:02.00]linha');
      expect(plus.lines.single.time, const Duration(milliseconds: 1500));

      final LrcLyrics minus = _parse('[offset:-300]\n[00:01.00]linha');
      expect(minus.lines.single.time, const Duration(milliseconds: 1300));

      final LrcLyrics none = _parse('[00:01.00]linha');
      expect(none.lines.single.time, const Duration(milliseconds: 1000));
    });

    test('offset no FIM do arquivo vale para as linhas de cima', () {
      final LrcLyrics lyrics = _parse(
        '[00:01.00]a\n'
        '[00:02.00]b\n'
        '[offset:200]',
      );
      expect(lyrics.lines[0].time, const Duration(milliseconds: 800));
      expect(lyrics.lines[1].time, const Duration(milliseconds: 1800));
    });

    test('múltiplos timestamps na mesma linha geram uma entrada cada', () {
      final LrcLyrics lyrics = _parse('[00:03.50][00:01.00]refrão');
      expect(lyrics.lines, hasLength(2));
      // Ordena por tempo; as duas entradas mantêm o texto.
      expect(lyrics.lines[0].time, const Duration(milliseconds: 1000));
      expect(lyrics.lines[1].time, const Duration(milliseconds: 3500));
      expect(lyrics.lines[0].text, 'refrão');
      expect(lyrics.lines[1].text, 'refrão');
    });

    test('linhas sem tempo e metadados ficam fora da sincronização', () {
      final LrcLyrics lyrics = _parse(
        '[ti:Faixa]\n'
        '[ar:Artista]\n'
        'texto solto\n'
        '[00:01.00]linha certa\n'
        'comentário solto',
      );
      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines.single.text, 'linha certa');
    });

    test('só linhas sem tempo (ou vazio) devolve null', () {
      expect(LrcLyrics.parse(''), isNull);
      expect(LrcLyrics.parse('[ti:x]\n'), isNull);
      expect(LrcLyrics.parse('apenas texto\n[ar:y]'), isNull);
    });

    test('formatos de fração: centésimos, milissegundos, sem e com ":"',
        () {
      expect(
        _parse('[00:01.5]a').lines.single.time,
        const Duration(milliseconds: 1500),
      );
      expect(
        _parse('[00:01.50]b').lines.single.time,
        const Duration(milliseconds: 1500),
      );
      expect(
        _parse('[00:01.500]c').lines.single.time,
        const Duration(milliseconds: 1500),
      );
      expect(
        _parse('[00:01]d').lines.single.time,
        const Duration(milliseconds: 1000),
      );
      // Compatibilidade: ':' como separador da fração (centésimos).
      expect(
        _parse('[00:01:25]e').lines.single.time,
        const Duration(milliseconds: 1250),
      );
    });

    test('ordena por tempo preservando o arquivo em empates', () {
      final LrcLyrics lyrics = _parse(
        '[00:05.00]B\n'
        '[00:05.00]A\n'
        '[00:01.00]C',
      );
      expect(
        lyrics.lines.map((LrcLine l) => l.text).toList(),
        <String>['C', 'B', 'A'],
      );
    });
  });

  group('indexAt — destaque da linha atual', () {
    test('bisseção: antes da primeira = -1, depois acompanha', () {
      final LrcLyrics lyrics = _parse(
        '[00:01.00]a\n[00:03.00]b\n[00:06.00]c',
      );
      expect(lyrics.indexAt(Duration.zero), -1);
      expect(lyrics.indexAt(const Duration(milliseconds: 999)), -1);
      expect(lyrics.indexAt(const Duration(milliseconds: 1000)), 0);
      expect(lyrics.indexAt(const Duration(milliseconds: 2999)), 0);
      expect(lyrics.indexAt(const Duration(milliseconds: 3000)), 1);
      expect(lyrics.indexAt(const Duration(minutes: 10)), 2);
    });

    test('texto corrido (letra embutida sem tempo) nunca destaca', () {
      final LrcLyrics unsynced = LrcLyrics.unsynced('a\nb');
      expect(unsynced.synced, isFalse);
      expect(unsynced.lines, hasLength(2));
      expect(unsynced.indexAt(const Duration(minutes: 5)), -1);
    });

    test('lista vazia devolve -1', () {
      final LrcLyrics empty = LrcLyrics(<LrcLine>[], synced: true);
      expect(empty.isEmpty, isTrue);
      expect(empty.indexAt(Duration.zero), -1);
    });
  });
}
