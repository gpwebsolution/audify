// Item 3.6 — parser de letras no formato LRC (offline, sem dependência).
//
// Formato aceito (o que se encontra em arquivos .lrc reais):
//  [mm:ss.xx] texto  — centésimos; também [mm:ss.xxx] (milissegundos),
//                      [mm:ss] (sem fração) e fração de 1..3 dígitos
//                      (preenchida à direita com 0: .5 = 500ms);
//  segundos aceitam 1..2 dígitos e o separador da fração também pode
//                      ser ':' (compatibilidade com arquivos não
//                      conformes: [3:12:5] = [3:12.5]);
//  VÁRIAS marcações na mesma linha geram uma entrada por marcação:
//      [00:01.00][00:05.00]refrão
//  [offset:±ms] — desloca TODAS as marcações. Convenção do formato
//      (Wikipédia: "+ causing lyrics to appear sooner"): valor
//      POSITIVO adianta a letra — a linha vale (timestamp − offset);
//      negativo atrasa;
//  linhas SEM marcação de tempo (inclui metadados [ti:], [ar:], [al:],
//  [by:], [length:] e texto corrido) são ignoradas na sincronização;
//  entradas com o MESMO tempo preservam a ordem do arquivo (sort
//  estável por índice — List.sort do Dart não é estável).

import 'dart:math' as math;

/// Uma linha da letra com o tempo efetivo ([offset] já aplicado).
class LrcLine {
  final Duration time;
  final String text;
  const LrcLine(this.time, this.text);
}

/// Letras de uma faixa: sincronizadas (LRC) ou texto corrido (letra
/// embutida sem timestamps — mostrada sem destaque).
class LrcLyrics {
  /// Linhas em ordem crescente de tempo; no modo texto corrido, na
  /// ordem do arquivo (time sempre zero, sem uso).
  final List<LrcLine> lines;

  /// true = há timestamps (destaque/rolagem por posição); false =
  /// texto corrido — [indexAt] devolve -1 e a UI não destaca nada.
  final bool synced;

  LrcLyrics(this.lines, {required this.synced});

  /// Texto sem timestamps (fallback da letra embutida USLT).
  factory LrcLyrics.unsynced(String text) => LrcLyrics(<LrcLine>[
    for (final String line in text.split(RegExp(r'\r?\n')))
      LrcLine(Duration.zero, line),
  ], synced: false);

  bool get isEmpty => lines.isEmpty;

  // Marcador de tempo: minutos (1..3), ':' , segundos (1..2) e
  // fração opcional com separador '.' ou ':'.
  static final RegExp _stamp = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,6}))?\]',
  );
  static final RegExp _offsetTag = RegExp(
    r'^\[offset:\s*([+-]?\d+)\s*\]$',
    caseSensitive: false,
  );

  /// Analisa o conteúdo de um .lrc. Devolve null quando nenhuma linha
  /// tem marcação de tempo (não há o que sincronizar).
  static LrcLyrics? parse(String source) {
    final List<String> rows = source.split(RegExp(r'\r?\n'));
    // Offset é GLOBAL: varre tudo antes de calcular os tempos, para o
    // [offset] valer mesmo quando aparece no fim do arquivo.
    int offsetMs = 0;
    for (final String raw in rows) {
      final Match? offset = _offsetTag.firstMatch(raw.trim());
      if (offset != null) {
        // int.parse aceita o sinal explícito ('+500').
        offsetMs = int.parse(offset.group(1)!);
        break;
      }
    }
    final List<(LrcLine, int)> tagged = <(LrcLine, int)>[];
    int seq = 0;
    for (final String raw in rows) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      if (_offsetTag.hasMatch(line)) continue;
      final List<RegExpMatch> stamps = _stamp.allMatches(line).toList();
      // Sem tempo = metadado/texto corrido: não vira linha sincronizada.
      if (stamps.isEmpty) continue;
      final String text = line.replaceAll(_stamp, '').trim();
      for (final RegExpMatch stamp in stamps) {
        final int baseMs =
            (int.parse(stamp.group(1)!) * 60 + int.parse(stamp.group(2)!)) *
            1000;
        final int ms = baseMs + _fractionMs(stamp.group(3));
        tagged.add((
          LrcLine(Duration(milliseconds: math.max(0, ms - offsetMs)), text),
          seq++,
        ));
      }
    }
    if (tagged.isEmpty) return null;
    tagged.sort(((LrcLine, int) a, (LrcLine, int) b) {
      final int cmp = a.$1.time.compareTo(b.$1.time);
      return cmp != 0 ? cmp : a.$2.compareTo(b.$2);
    });
    return LrcLyrics(<LrcLine>[
      for (final (LrcLine line, int _) in tagged) line,
    ], synced: true);
  }

  /// Fração do timestamp em ms: 1..3 dígitos preenchidos à direita
  /// ('.5' = 500ms), dígitos extras truncados nos 3 primeiros.
  static int _fractionMs(String? fraction) {
    if (fraction == null || fraction.isEmpty) return 0;
    final String padded = fraction.length >= 3
        ? fraction.substring(0, 3)
        : fraction.padRight(3, '0');
    return int.parse(padded);
  }

  /// Índice da última linha cujo tempo é <= [position] — bisseção
  /// (a lista pode ter milhares de linhas e isto roda a cada tick de
  /// posição). -1 = antes da primeira linha, texto corrido ou vazio.
  int indexAt(Duration position) {
    if (!synced || lines.isEmpty) return -1;
    int low = 0;
    int high = lines.length - 1;
    int best = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (lines[mid].time <= position) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }
}
