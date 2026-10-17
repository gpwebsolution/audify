import 'package:flutter/widgets.dart';

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
