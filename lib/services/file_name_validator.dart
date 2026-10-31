import 'dart:convert';

/// Validação única de nome de arquivo/pasta em todo o app.
///
/// Devolve `null` quando o nome é aceitável ou o motivo da recusa em
/// português. O objetivo é impedir caminhos que escapem da pasta atual
/// (`..`), nomes vazios/só pontos, NUL e caracteres reservados — e limitar
/// a 255 bytes, que é o teto do sistema de arquivos.
///
/// Não recebe caminho completo: o chamador separa o nome antes. Usado por
/// renomear, criar pasta, criar arquivo de texto e compactar em ZIP.
String? validateFileName(String name) {
  if (name.isEmpty) return 'Digite um nome.';
  if (name.trim().isEmpty) return 'O nome não pode ser só espaços.';

  // NUL e controles quebram APIs de arquivo (e o manifesto da lixeira).
  for (final int rune in name.runes) {
    if (rune < 0x20 || rune == 0x7F) {
      return 'O nome contém um caractere de controle inválido.';
    }
  }

  if (name == '.' || name == '..') return 'Nome inválido.';
  if (name.contains('/') || name.contains(r'\')) {
    return 'O nome não pode conter "/" nem "\\".';
  }

  // Reservados no Windows e problemáticos em compartilhamentos/SAF.
  const String reserved = '<>:"|?*';
  for (final int rune in name.runes) {
    if (reserved.codeUnits.contains(rune)) {
      return 'O nome não pode conter nenhum destes caracteres: $reserved';
    }
  }

  if (name.endsWith(' ') || name.endsWith('.')) {
    return 'O nome não pode terminar com espaço nem com ponto.';
  }

  if (utf8.encode(name).length > 255) {
    return 'Nome muito longo (máx. 255 bytes).';
  }

  // Nomes reservados do DOS/Windows (CON, PRN, AUX, NUL, COM1..9, LPT1..9).
  final String stem = name.split('.').first.toUpperCase();
  const Set<String> dosReserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (dosReserved.contains(stem)) {
    return 'Este nome é reservado pelo sistema.';
  }

  return null;
}
