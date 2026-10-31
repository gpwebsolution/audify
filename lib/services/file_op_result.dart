/// Resultado tipado de uma operação de arquivo.
///
/// Substitui o `bool` mudo: quando algo falha, a interface consegue mostrar
/// o motivo em português em vez de um "não foi possível" genérico.
enum FileOpErrorCode {
  permission,
  io,
  notFound,
  unsupported,
  unsafePath,
  limitExceeded,
  alreadyExists,
  cancelled,
}

class FileOpResult {
  /// Operação concluída (total ou parcialmente).
  final bool ok;

  /// Concluída em parte: algo foi feito, mas nem tudo.
  final bool partial;

  /// Código estável para o chamador decidir o que fazer.
  final FileOpErrorCode? code;

  /// Motivo legível (pt-BR) quando `ok == false` ou `partial == true`.
  final String? reason;

  /// Caminho final quando a operação gera/restaura um arquivo.
  final String? path;

  const FileOpResult.ok({this.path})
    : ok = true,
      partial = false,
      code = null,
      reason = null;

  const FileOpResult.partial({
    required String this.reason,
    this.code = FileOpErrorCode.io,
    this.path,
  }) : ok = true,
       partial = true;

  const FileOpResult.failed({
    required String this.reason,
    required this.code,
    this.path,
  }) : ok = false,
       partial = false;
}
