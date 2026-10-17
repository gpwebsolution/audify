/// Item 4.3 — critérios de ordenação da biblioteca (aba Música).
///
/// `name` serializado no SharedPreferences (`library_sort_key`). Os
/// rótulos exibidos no menu "Ordenar" são traduzidos na UI pelo item
/// 5.1 (chaves `sortKey*` do app_localizations) — nada de texto pronto
/// aqui.
enum SongSortKey {
  title,
  artist,
  album,
  dateAdded,
  duration,
  mostPlayed;

  /// Restaura a partir do valor persistido; string desconhecida
  /// (banco corrompido/antigo) volta para o padrão — título.
  static SongSortKey fromName(String? name) =>
      SongSortKey.values.firstWhere(
        (SongSortKey k) => k.name == name,
        orElse: () => SongSortKey.title,
      );
}
