/// Normalização de texto para COMPARAÇÃO — item 2.3 (busca, ordenação e
/// agrupamento da biblioteca de músicas).
///
/// Problema que resolve: `toLowerCase()` puro deixa diacríticos de pé —
/// "Árvore" ordenava depois de "Zebra" e buscar "acao" não achava
/// "Ação". Aqui a chave de comparação vira minúsculas SEM acento, e a
/// ordenação ganha ordem natural ("Faixa 2" antes de "Faixa 10").
///
/// Sem dependência nova: mapa explícito dos diacríticos comuns de
/// pt-BR/ES/FR (o que o teclado e o MediaStore produzem). O texto de
/// EXIBIÇÃO nunca passa por aqui — só as chaves de comparação.
library;

/// Diacríticos minúsculos -> letra base ('œ'/'æ' viram as duplas, que o
/// decompor Unicode não toca: são letras, não acentos).
const Map<String, String> _lowerDiacritics = <String, String>{
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ç': 'c',
  'ñ': 'n',
  'œ': 'oe',
  'æ': 'ae',
  'ø': 'o',
  'đ': 'd',
  'ł': 'l',
  'þ': 'th',
};

/// Tabela com as duas caixas ('á'->'a' e 'Á'->'A'): [stripDiacritics]
/// preserva a caixa do texto de entrada.
final Map<String, String> _diacriticsTable = <String, String>{
  for (final MapEntry<String, String> entry
      in _lowerDiacritics.entries) ...<String, String>{
    entry.key: entry.value,
    entry.key.toUpperCase(): entry.value.toUpperCase(),
  },
};

/// Remove diacríticos comuns (pt-BR/ES/FR) mantendo a caixa:
/// 'Ação' -> 'Acao', 'Señor' -> 'Senor', 'cœur' -> 'coeur'.
/// O que não está no mapa (letras simples, números, símbolos, emoji)
/// passa intacto.
String stripDiacritics(String input) {
  if (input.isEmpty) return input;
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    final String char = input[i];
    out.write(_diacriticsTable[char] ?? char);
  }
  return out.toString();
}

/// Chave de comparação: minúsculas SEM diacríticos — o que busca,
/// ordenação e agrupamento usam para comparar.
/// 'AÇÃO' / 'acao' / 'Ação' -> 'acao'.
String normalizeKey(String input) => stripDiacritics(input.toLowerCase());

/// Ordem NATURAL insensível a caixa/acentos: trechos numéricos valem
/// pelo valor, então 'Faixa 2' vem antes de 'Faixa 10', e 'Árvore'
/// antes de 'Zebra'. Aceita texto cru (normaliza por conta própria).
///
/// Números com zeros à esquerda empatam de propósito ('Faixa 02' ==
/// 'Faixa 2' — a ordem final cai no resto da string, estável).
int naturalCompare(String a, String b) {
  final String left = normalizeKey(a);
  final String right = normalizeKey(b);
  int i = 0;
  int j = 0;
  while (i < left.length && j < right.length) {
    final bool digitA = _isDigit(left.codeUnitAt(i));
    final bool digitB = _isDigit(right.codeUnitAt(j));
    if (digitA && digitB) {
      final int startA = i;
      final int startB = j;
      while (i < left.length && _isDigit(left.codeUnitAt(i))) {
        i++;
      }
      while (j < right.length && _isDigit(right.codeUnitAt(j))) {
        j++;
      }
      final int cmp = _compareNumbers(
        left.substring(startA, i),
        right.substring(startB, j),
      );
      if (cmp != 0) return cmp;
      continue; // mesmo número ('007' == '7'): segue daqui
    }
    if (left.codeUnitAt(i) != right.codeUnitAt(j)) {
      return left.codeUnitAt(i).compareTo(right.codeUnitAt(j));
    }
    i++;
    j++;
  }
  // Um dos lados acabou: o mais curto vem primeiro.
  return (left.length - i).compareTo(right.length - j);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Compara dois trechos numéricos SEM parsear (nada de estourar int com
/// um nome de arquivo de 40 dígitos): primeiro o comprimento sem zeros
/// à esquerda (menor número tem menos dígitos), depois o lexicográfico.
int _compareNumbers(String a, String b) {
  final String trimmedA = _trimLeadingZeros(a);
  final String trimmedB = _trimLeadingZeros(b);
  if (trimmedA.length != trimmedB.length) {
    return trimmedA.length.compareTo(trimmedB.length);
  }
  return trimmedA.compareTo(trimmedB);
}

String _trimLeadingZeros(String digits) {
  int k = 0;
  while (k < digits.length - 1 && digits[k] == '0') {
    k++;
  }
  return digits.substring(k);
}
