import 'dart:convert';
import 'dart:io';

/// Criação e edição de arquivos de texto simples (HTML, CSS, JS, JSON, MD,
/// XML, log, TXT).
///
/// Existe porque o app só tinha "Nova pasta". Sem isso, criar um `index.html`
/// significava sair do app, abrir o Bloco de Notas do sistema e voltar — e o
/// arquivo criado não aparecia na lista até um "Atualizar" manual.
class TextFileService {
  const TextFileService._();

  /// Extensões tratadas como texto.
  ///
  /// Lista fechada de propósito: abrir um arquivo binário (mp4, apk, banco) no
  /// editor de texto mostraria lixo e, ao salvar, CORRUPERIRIA o arquivo.
  static const List<String> textExtensions = <String>[
    'txt',
    'html',
    'htm',
    'css',
    'js',
    'json',
    'md',
    'xml',
    'log',
    'csv',
    'yaml',
    'yml',
    'ini',
    'conf',
  ];

  /// Maior arquivo que o editor abre (2 MB).
  ///
  /// Acima disso o conteúdo vira uma parede de texto que trava o scroll, e o
  /// usuário quase sempre quis outra coisa. O limite é explícito na UI.
  static const int maxEditableBytes = 2 * 1024 * 1024;

  static bool isTextFile(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot <= 0) return false;
    return textExtensions.contains(path.substring(dot + 1).toLowerCase());
  }

  static String? extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// True quando o nome parece um arquivo de texto editável.
  static bool hasEditableExtension(String name) {
    final String? ext = extensionOf(name);
    return ext != null && textExtensions.contains(ext);
  }

  /// Verifica se um nome é válido para criar arquivo.
  ///
  /// Devolve null quando válido, ou o motivo da recusa — a UI mostra a razão,
  /// em vez de falhar e deixar o usuário sem explicação.
  static String? validateName(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return 'Digite um nome.';
    if (trimmed == '.' || trimmed == '..') return 'Nome inválido.';
    if (trimmed.contains('/')) {
      return 'O nome não pode conter "/" — crie uma pasta se quiser organizar.';
    }
    if (trimmed.length > 120) return 'Nome muito longo (máx. 120).';
    final String? ext = extensionOf(trimmed);
    if (ext == null) {
      return 'Inclua a extensão, por exemplo ".html" ou ".txt".';
    }
    if (!textExtensions.contains(ext)) {
      return '".$ext" não é um tipo de texto. '
          'Tipos aceitos: ${textExtensions.join(', ')}.';
    }
    return null;
  }

  /// Cria um arquivo de texto em [directory].
  ///
  /// [content] vazio recebe o esqueleto da extensão ([starterContent]): um
  /// `index.html` em branco é inútil e o usuário acabaria abrindo outro
  /// programa só para escrever `<!DOCTYPE html>`.
  ///
  /// Não sobrescreve: se já existir um arquivo com o mesmo nome, escolhe
  /// "nome (1).ext". Apagar o trabalho do usuário sem querer é o pior
  /// resultado possível para "criar arquivo".
  static Future<TextFileResult> create({
    required String directory,
    required String name,
    String content = '',
  }) async {
    final String? problem = validateName(name);
    if (problem != null) return TextFileResult.failed(problem);

    final String ext = extensionOf(name.trim())!;
    String target = '$directory/${name.trim()}';
    if (File(target).existsSync()) {
      final String base = name.trim().substring(
        0,
        name.trim().length - ext.length - 1,
      );
      for (int i = 1; i < 100; i++) {
        final String candidate = '$directory/$base ($i).$ext';
        if (!File(candidate).existsSync()) {
          target = candidate;
          break;
        }
      }
    }

    final String body = content.isEmpty ? starterContent(ext) : content;
    try {
      final File file = await File(target).writeAsString(body, flush: true);
      return TextFileResult.ok(file.path);
    } catch (e) {
      return TextFileResult.failed('Não foi possível criar o arquivo: $e');
    }
  }

  /// Lê um arquivo de texto.
  static Future<TextFileResult> read(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      return TextFileResult.failed('Arquivo não encontrado.');
    }
    if (!isTextFile(path)) {
      return TextFileResult.failed(
        'Este não é um arquivo de texto. Use um app specialised para ele.',
      );
    }
    final int length = file.lengthSync();
    if (length > maxEditableBytes) {
      return TextFileResult.failed(
        'Arquivo muito grande (${_human(length)}). '
        'O editor abre arquivos de até ${_human(maxEditableBytes)}.',
      );
    }
    try {
      final String content = await file.readAsString();
      return TextFileResult.ok(path, content: content);
    } catch (e) {
      return TextFileResult.failed('Não foi possível ler o arquivo: $e');
    }
  }

  /// Grava o conteúdo em [path].
  static Future<TextFileResult> write(String path, String content) async {
    try {
      await File(path).writeAsString(content, flush: true);
      return TextFileResult.ok(path, content: content);
    } catch (e) {
      return TextFileResult.failed('Não foi possível salvar: $e');
    }
  }

  /// Verifica se o nome está livre dentro de [directory].
  static bool isNameFree(String directory, String name) =>
      !File('$directory/${name.trim()}').existsSync();

  static String _human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Conteúdo inicial por extensão, para não começar com um arquivo vazio.
  ///
  /// Um `index.html` em branco é inútil; um esqueleto com as tags básicas dá
  /// por onde começar.
  static String starterContent(String extension) {
    switch (extension) {
      case 'html':
      case 'htm':
        return '<!DOCTYPE html>\n'
            '<html lang="pt-BR">\n'
            '<head>\n'
            '  <meta charset="UTF-8">\n'
            '  <meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
            '  <title>Nova página</title>\n'
            '</head>\n'
            '<body>\n'
            '  <h1>Olá</h1>\n'
            '</body>\n'
            '</html>\n';
      case 'css':
        return '/* Estilos */\n'
            'body {\n'
            '  font-family: sans-serif;\n'
            '}\n';
      case 'js':
        return '// JavaScript\n';
      case 'json':
        return '{\n  \n}\n';
      case 'xml':
        return '<?xml version="1.0" encoding="UTF-8"?>\n<root>\n</root>\n';
      case 'md':
        return '# Título\n\nEscreva aqui.\n';
      default:
        return '';
    }
  }

  /// Valida JSON e devolve o erro de sintaxe, quando houver.
  ///
  /// Usado pelo editor para avisar antes de salvar um JSON quebrado — que é o
  /// tipo de erro que só aparece muito depois, em outro programa.
  static String? validateJson(String content) {
    try {
      jsonDecode(content);
      return null;
    } on FormatException catch (e) {
      return 'JSON inválido: ${e.message}';
    }
  }
}

/// Resultado de uma operação de arquivo de texto.
class TextFileResult {
  /// True quando deu certo.
  final bool success;

  /// Caminho do arquivo em disco (vazio em caso de falha).
  final String path;

  /// Conteúdo lido, quando aplicável.
  final String? content;

  /// Motivo da falha, legível — nunca null quando [success] é false.
  final String? error;

  const TextFileResult({
    required this.success,
    required this.path,
    this.content,
    this.error,
  });

  /// Sucesso, opcionalmente com o conteúdo que foi lido.
  factory TextFileResult.ok(String path, {String? content}) =>
      TextFileResult(success: true, path: path, content: content);

  /// Falha com o motivo já pronto para a UI mostrar.
  factory TextFileResult.failed(String error) =>
      TextFileResult(success: false, path: '', error: error);
}
