import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Log de erros 100% LOCAL (o app é offline/privado — nada sai do
/// aparelho).
///
/// Responsabilidade: persistir as últimas falhas não tratadas (exceções
/// da zona, erros do framework Flutter e erros assíncronos do
/// platform dispatcher) em `crash_log.txt` dentro do diretório de
/// documentos do app. Na próxima abertura é possível diagnosticar um
/// crash que aconteceu com o app fechado — sem telemetria, sem nuvem.
///
/// Design defensivo: NENHUM método lança. Se o disco falhar (permissão,
/// espaço), o log vira no-op e o app segue funcionando — a última coisa
/// que um tratador de erro pode fazer é ele próprio estourar uma
/// exceção e derrubar o processo.
class ErrorLogService {
  ErrorLogService._();

  static const String _fileName = 'crash_log.txt';

  /// Teto do arquivo (~128 KB). Ao exceder, mantém apenas a metade mais
  /// recente — o log nunca cresce indefinidamente.
  static const int _maxFileBytes = 128 * 1024;

  /// Limite de entradas em memória (para leitura rápida na UI).
  static const int _maxMemoryEntries = 100;

  static final List<String> _memoryBuffer = <String>[];
  static File? _file;
  static bool _initialized = false;

  /// Prepara o arquivo de destino. Seguro chamar mais de uma vez; se o
  /// path_provider falhar (teste unitário/plataforma sem suporte),
  /// apenas registra em memória.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final Directory appDir = Directory('${dir.path}/logs');
      if (!appDir.existsSync()) appDir.createSync(recursive: true);
      _file = File('${appDir.path}/$_fileName');
    } catch (e) {
      // Sem acesso a diretórios (ex.: testes): só buffer em memória.
      debugPrint('[ErrorLog] Sem diretório de logs: $e');
      _file = null;
    }
  }

  /// Registra um erro com stack trace opcional (persistido + memória).
  static Future<void> log(
    String source,
    Object error,
    StackTrace? stack,
  ) async {
    final String entry = _format(source, error, stack);
    _appendMemory(entry);
    await _appendFile(entry);
  }

  /// Versão síncrona para uso dentro de tratadores que não podem
  /// aguardar (FlutterError.onError roda durante o build).
  static void logSync(String source, Object error, StackTrace? stack) {
    final String entry = _format(source, error, stack);
    _appendMemory(entry);
    // Escrita fire-and-forget: erro aqui já foi capturado dentro.
    _appendFile(entry).catchError((Object _) {});
    if (kDebugMode) {
      debugPrint('[ErrorLog/$source] $error');
    }
  }

  /// Lê todo o conteúdo do log (UI -> Configurações). Null = sem log.
  static Future<String?> read() async {
    try {
      final File? file = _file;
      if (file == null || !file.existsSync()) return null;
      final String content = await file.readAsString();
      return content.isEmpty ? null : content;
    } catch (e) {
      debugPrint('[ErrorLog] Falha ao ler log: $e');
      return null;
    }
  }

  /// Caminho do arquivo (para "exportar/compartilhar" nas Configurações).
  static String? get filePath => _file?.path;

  /// Apaga o log (botão "limpar" das Configurações).
  static Future<void> clear() async {
    _memoryBuffer.clear();
    try {
      final File? file = _file;
      if (file != null && file.existsSync()) {
        await file.writeAsString('', flush: true);
      }
    } catch (e) {
      debugPrint('[ErrorLog] Falha ao limpar log: $e');
    }
  }

  // -----------------------------------------------------------------

  static String _format(String source, Object error, StackTrace? stack) {
    final DateTime now = DateTime.now();
    final String ts =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final StringBuffer buf = StringBuffer()
      ..writeln('[$ts][$source] $error');
    if (stack != null && stack.toString().isNotEmpty) {
      buf.writeln(stack.toString());
    }
    buf.writeln('---');
    return buf.toString();
  }

  static void _appendMemory(String entry) {
    _memoryBuffer.add(entry);
    while (_memoryBuffer.length > _maxMemoryEntries) {
      _memoryBuffer.removeAt(0);
    }
  }

  static Future<void> _appendFile(String entry) async {
    try {
      final File? file = _file;
      if (file == null) return;
      RandomAccessFile handle = await file.open(mode: FileMode.append);
      try {
        await handle.writeString(entry);
        await handle.flush();
      } finally {
        await handle.close();
      }

      // Rotação simples: acima do teto, mantém a metade final do arquivo.
      final int size = await file.length();
      if (size > _maxFileBytes) {
        final String content = await file.readAsString();
        final String kept = content.substring(content.length ~/ 2);
        await file.writeAsString(kept, flush: true);
      }
    } catch (e) {
      // Disco indisponível: log vira no-op silencioso.
      debugPrint('[ErrorLog] Falha ao gravar log: $e');
    }
  }

  /// Entradas recentes em memória (útil antes do init terminar).
  static List<String> get memoryEntries =>
      List.unmodifiable(_memoryBuffer);

  /// Dump do buffer de memória (fallback quando não há arquivo).
  static String get memoryDump => _memoryBuffer.join();

  /// jsonEncode exposto para quem quiser anexar contexto estruturado.
  static String encode(Object? value) => jsonEncode(value);
}
