/// Idioma escolhido pelo usuário (item 5.1 — Configurações > Aparência).
///
/// `name` serializado no SharedPreferences (`locale_choice`); `system`
/// segue o locale do aparelho com fallback pt-BR (ver o
/// `localeListResolutionCallback` no main.dart).
enum AppLocaleChoice {
  /// Segue o sistema.
  system,

  /// Português fixo.
  portuguese,

  /// Inglês fixo.
  english;

  /// Restaura a partir do valor persistido; string desconhecida
  /// (banco corrompido/antigo) volta para o padrão — sistema.
  static AppLocaleChoice fromName(String? name) =>
      AppLocaleChoice.values.firstWhere(
        (AppLocaleChoice c) => c.name == name,
        orElse: () => AppLocaleChoice.system,
      );
}
