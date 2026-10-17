/// Item 4.3 — critérios de ordenação da biblioteca (aba Música).
///
/// `name` serializado no SharedPreferences (`library_sort_key`); [label]
/// é o texto mostrado no menu "Ordenar". Rótulos em pt-BR direto no
/// enum — a internacionalização (item 5.1) vai tratá-los junto com as
/// demais strings quando chegar a vez dela.
enum SongSortKey {
  title('Título'),
  artist('Artista'),
  album('Álbum'),
  dateAdded('Data de adição'),
  duration('Duração'),
  mostPlayed('Mais tocadas');

  const SongSortKey(this.label);

  /// Rótulo para a UI.
  final String label;

  /// Restaura a partir do valor persistido; string desconhecida
  /// (banco corrompido/antigo) volta para o padrão — título.
  static SongSortKey fromName(String? name) =>
      SongSortKey.values.firstWhere(
        (SongSortKey k) => k.name == name,
        orElse: () => SongSortKey.title,
      );
}
