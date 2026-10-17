import 'package:flutter/widgets.dart';

import '../models/song_sort_key.dart';
import 'app_localizations.dart';
import 'app_localizations_pt.dart';

/// As localizações do app com fallback pt-BR (item 5.1).
///
/// O app registra [AppLocalizations.delegate] no MaterialApp; widgets
/// órfãos que montam um MaterialApp sem os delegates (harness de teste,
/// previews) caem no pt-BR em vez de estourar null-check — o mesmo
/// fallback previsto para idiomas não suportados.
AppLocalizations l10nOf(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizationsPt();

/// Rótulo do critério de ordenação (itens 4.3/5.1/5.2) — compartilhado
/// entre o menu da tela de músicas e a seção Biblioteca de
/// Configurações.
extension SortKeyL10n on AppLocalizations {
  String sortKeyLabel(SongSortKey key) {
    switch (key) {
      case SongSortKey.title:
        return sortKeyTitle;
      case SongSortKey.artist:
        return sortKeyArtist;
      case SongSortKey.album:
        return sortKeyAlbum;
      case SongSortKey.dateAdded:
        return sortKeyDateAdded;
      case SongSortKey.duration:
        return sortKeyDuration;
      case SongSortKey.mostPlayed:
        return sortKeyMostPlayed;
    }
  }
}
