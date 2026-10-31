import '../models/song_model.dart';
import '../models/song_sort_key.dart';
import 'text_normalize.dart';

/// Item 4.3 — comparação de faixas pela ordenação escolhida.
///
/// Regras comuns a todos os critérios:
///  - sem dado (data/duração nulas) o item NUNCA disputa: fica por
///    último em qualquer direção;
///  - desempate por título natural (mesma ordem do catálogo — o resto
///    da tela já pensa nela);
///  - [ascending] false inverte o critério E o desempate (nulos
///    continuam por último — a inversão é só entre valores conhecidos).
///
/// [playCounts] entra só em [SongSortKey.mostPlayed] (id → contagem do
/// histórico); sem dado, a faixa vale 0.
int compareSongs(
  Song a,
  Song b, {
  required SongSortKey key,
  required bool ascending,
  Map<String, int> playCounts = const <String, int>{},
}) {
  final bool aMissing = _isMissing(key, a);
  final bool bMissing = _isMissing(key, b);
  if (aMissing || bMissing) {
    if (aMissing && bMissing) {
      return ascending
          ? naturalCompare(a.title, b.title)
          : -naturalCompare(a.title, b.title);
    }
    return aMissing ? 1 : -1;
  }

  final int primary = switch (key) {
    SongSortKey.title => naturalCompare(a.title, b.title),
    SongSortKey.artist => naturalCompare(a.displayArtist, b.displayArtist),
    SongSortKey.album => naturalCompare(a.album ?? '', b.album ?? ''),
    SongSortKey.dateAdded => (a.dateAdded!).compareTo(b.dateAdded!),
    SongSortKey.duration =>
      (a.duration ?? Duration.zero).inMilliseconds.compareTo(
        (b.duration ?? Duration.zero).inMilliseconds,
      ),
    SongSortKey.mostPlayed => (playCounts[a.id] ?? 0).compareTo(
      playCounts[b.id] ?? 0,
    ),
  };
  final int directed = ascending ? primary : -primary;
  if (directed != 0) return directed;
  final int tiebreak = naturalCompare(a.title, b.title);
  return ascending ? tiebreak : -tiebreak;
}

/// Ordenação interna de um grupo de ÁLBUM: número da faixa crescente
/// (o que vem do disco primeiro, independente do sentido global), sem
/// número no fim e título natural no desempate.
int compareByTrack(Song a, Song b) {
  final int? ta = a.trackNumber;
  final int? tb = b.trackNumber;
  if (ta == null && tb == null) return naturalCompare(a.title, b.title);
  if (ta == null) return 1;
  if (tb == null) return -1;
  final int primary = ta.compareTo(tb);
  return primary != 0 ? primary : naturalCompare(a.title, b.title);
}

bool _isMissing(SongSortKey key, Song song) {
  switch (key) {
    case SongSortKey.dateAdded:
      return song.dateAdded == null;
    case SongSortKey.duration:
      return song.duration == null;
    case SongSortKey.title:
    case SongSortKey.artist:
    case SongSortKey.album:
    case SongSortKey.mostPlayed:
      return false;
  }
}
