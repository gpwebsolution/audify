import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pt'),
  ];

  /// Nome do app
  ///
  /// In pt, this message translates to:
  /// **'Audify'**
  String get appTitle;

  /// No description provided for @aboutSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Player de mídia local — músicas, vídeos, fotos e PDFs.\nFeito por GpWebSolution'**
  String get aboutSubtitle;

  /// No description provided for @aboutVersion.
  ///
  /// In pt, this message translates to:
  /// **'Versão {version}'**
  String aboutVersion(String version);

  /// No description provided for @addButton.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar'**
  String get addButton;

  /// No description provided for @addedManyToPlaylist.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} adicionada a \"{name}\"} other{{count} adicionadas a \"{name}\"}}'**
  String addedManyToPlaylist(num count, Object name);

  /// No description provided for @addedPartialToPlaylist.
  ///
  /// In pt, this message translates to:
  /// **'{added} de {total} adicionadas a \"{name}\"'**
  String addedPartialToPlaylist(int added, int total, String name);

  /// No description provided for @addedToPlaylist.
  ///
  /// In pt, this message translates to:
  /// **'Adicionada a \"{name}\"'**
  String addedToPlaylist(String name);

  /// No description provided for @addToPlaylist.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar à playlist'**
  String get addToPlaylist;

  /// No description provided for @allowBtn.
  ///
  /// In pt, this message translates to:
  /// **'Permitir'**
  String get allowBtn;

  /// No description provided for @appearanceTitle.
  ///
  /// In pt, this message translates to:
  /// **'Aparência'**
  String get appearanceTitle;

  /// No description provided for @atTrackEnd.
  ///
  /// In pt, this message translates to:
  /// **'Ao fim da faixa'**
  String get atTrackEnd;

  /// No description provided for @atTrackEndSub.
  ///
  /// In pt, this message translates to:
  /// **'Para no fim desta faixa, sem pular para a próxima'**
  String get atTrackEndSub;

  /// No description provided for @batterySub.
  ///
  /// In pt, this message translates to:
  /// **'Recomendado: sem isso, Xiaomi/Samsung/Motorola podem parar a música em segundo plano.'**
  String get batterySub;

  /// No description provided for @batteryTitle.
  ///
  /// In pt, this message translates to:
  /// **'Ignorar otimização de bateria'**
  String get batteryTitle;

  /// No description provided for @cancel.
  ///
  /// In pt, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @clearButton.
  ///
  /// In pt, this message translates to:
  /// **'Limpar'**
  String get clearButton;

  /// No description provided for @clearSearchTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Limpar busca'**
  String get clearSearchTooltip;

  /// No description provided for @closeButton.
  ///
  /// In pt, this message translates to:
  /// **'Fechar'**
  String get closeButton;

  /// No description provided for @collapseTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Recolher'**
  String get collapseTooltip;

  /// No description provided for @crossfadeDirect.
  ///
  /// In pt, this message translates to:
  /// **'Troca de faixa direta (padrão).'**
  String get crossfadeDirect;

  /// No description provided for @crossfadeOverlap.
  ///
  /// In pt, this message translates to:
  /// **'Nos últimos {n}s da faixa e nos primeiros {n}s da próxima, o volume faz a transição.'**
  String crossfadeOverlap(int n);

  /// No description provided for @crossfadeSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Transição suave entre faixas — o fim da atual cai e a próxima sobe em volume (sem intervalo).'**
  String get crossfadeSubtitle;

  /// No description provided for @crossfadeTitle.
  ///
  /// In pt, this message translates to:
  /// **'Crossfade'**
  String get crossfadeTitle;

  /// No description provided for @customSleep.
  ///
  /// In pt, this message translates to:
  /// **'Personalizado'**
  String get customSleep;

  /// No description provided for @customSleepSub.
  ///
  /// In pt, this message translates to:
  /// **'De 1 a 720 minutos'**
  String get customSleepSub;

  /// No description provided for @customTimerTitle.
  ///
  /// In pt, this message translates to:
  /// **'Timer personalizado'**
  String get customTimerTitle;

  /// No description provided for @deleteFromDevice.
  ///
  /// In pt, this message translates to:
  /// **'Excluir do aparelho'**
  String get deleteFromDevice;

  /// No description provided for @deleteSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'{title} • o Android pedirá confirmação'**
  String deleteSubtitle(String title);

  /// No description provided for @deleteTrackGoneSub.
  ///
  /// In pt, this message translates to:
  /// **'Some da lista, da fila e das playlists'**
  String get deleteTrackGoneSub;

  /// No description provided for @details.
  ///
  /// In pt, this message translates to:
  /// **'Detalhes'**
  String get details;

  /// No description provided for @detailsSub.
  ///
  /// In pt, this message translates to:
  /// **'Álbum, artista, tamanho e caminho'**
  String get detailsSub;

  /// No description provided for @emptyNoMusic.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma música encontrada.\nAdicione arquivos .mp3 em assets/songs/ ou no aparelho.'**
  String get emptyNoMusic;

  /// No description provided for @emptyNoResults.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum resultado para \"{query}\".'**
  String emptyNoResults(String query);

  /// No description provided for @emptyPermissionDenied.
  ///
  /// In pt, this message translates to:
  /// **'Permissão de acesso às músicas negada.\nPermita acima para ver as músicas do aparelho.'**
  String get emptyPermissionDenied;

  /// No description provided for @equalizerSettingsSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Bandas, presets e reforço de graves.'**
  String get equalizerSettingsSubtitle;

  /// No description provided for @equalizerSheetSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Bandas, presets e reforço de graves'**
  String get equalizerSheetSubtitle;

  /// No description provided for @equalizerTitle.
  ///
  /// In pt, this message translates to:
  /// **'Equalizador'**
  String get equalizerTitle;

  /// No description provided for @errorLogSub.
  ///
  /// In pt, this message translates to:
  /// **'Diagnóstico local (fica só no aparelho).'**
  String get errorLogSub;

  /// No description provided for @errorLogTitle.
  ///
  /// In pt, this message translates to:
  /// **'Log de erros'**
  String get errorLogTitle;

  /// No description provided for @expandTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Expandir'**
  String get expandTooltip;

  /// No description provided for @favorite.
  ///
  /// In pt, this message translates to:
  /// **'Favoritar'**
  String get favorite;

  /// No description provided for @favoriteOffSub.
  ///
  /// In pt, this message translates to:
  /// **'Some da playlist Favoritas'**
  String get favoriteOffSub;

  /// No description provided for @favoriteOnSub.
  ///
  /// In pt, this message translates to:
  /// **'Entra na playlist Favoritas'**
  String get favoriteOnSub;

  /// No description provided for @foreverOption.
  ///
  /// In pt, this message translates to:
  /// **'Para sempre'**
  String get foreverOption;

  /// No description provided for @groupAlbum.
  ///
  /// In pt, this message translates to:
  /// **'Álbum'**
  String get groupAlbum;

  /// No description provided for @groupArtist.
  ///
  /// In pt, this message translates to:
  /// **'Artista'**
  String get groupArtist;

  /// No description provided for @groupFolder.
  ///
  /// In pt, this message translates to:
  /// **'Pasta'**
  String get groupFolder;

  /// No description provided for @groupTracks.
  ///
  /// In pt, this message translates to:
  /// **'Faixas'**
  String get groupTracks;

  /// No description provided for @ignoredFoldersCount.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} pasta fora da biblioteca.} other{{count} pastas fora da biblioteca.}}'**
  String ignoredFoldersCount(num count);

  /// No description provided for @ignoredFoldersEmptySub.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma. Áudios de WhatsApp/toques ficam misturados se o MediaStore marcar como música.'**
  String get ignoredFoldersEmptySub;

  /// No description provided for @ignoredFoldersSheetSub.
  ///
  /// In pt, this message translates to:
  /// **'Faixas DENTRO da pasta somem da biblioteca. Cole o caminho da pasta (subpastas também contam).'**
  String get ignoredFoldersSheetSub;

  /// No description provided for @ignoredFoldersTitle.
  ///
  /// In pt, this message translates to:
  /// **'Pastas ignoradas'**
  String get ignoredFoldersTitle;

  /// No description provided for @invertSelection.
  ///
  /// In pt, this message translates to:
  /// **'Inverter seleção'**
  String get invertSelection;

  /// No description provided for @languageEnglish.
  ///
  /// In pt, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languagePortuguese.
  ///
  /// In pt, this message translates to:
  /// **'Português'**
  String get languagePortuguese;

  /// No description provided for @languageSection.
  ///
  /// In pt, this message translates to:
  /// **'Idioma'**
  String get languageSection;

  /// No description provided for @licensesSub.
  ///
  /// In pt, this message translates to:
  /// **'Bibliotecas usadas no app.'**
  String get licensesSub;

  /// No description provided for @licensesTitle.
  ///
  /// In pt, this message translates to:
  /// **'Licenças de código aberto'**
  String get licensesTitle;

  /// No description provided for @minDurationAll.
  ///
  /// In pt, this message translates to:
  /// **'Todas as faixas aparecem (padrão).'**
  String get minDurationAll;

  /// No description provided for @minDurationHide.
  ///
  /// In pt, this message translates to:
  /// **'Esconde faixas com menos de {label} — toques e notificações somem.'**
  String minDurationHide(String label);

  /// No description provided for @minDurationHideShort.
  ///
  /// In pt, this message translates to:
  /// **'Esconde do catálogo o que tiver menos de {label} — some com toques e notificações curtas.'**
  String minDurationHideShort(String label);

  /// No description provided for @minDurationShowAll.
  ///
  /// In pt, this message translates to:
  /// **'Mostra todas as faixas (padrão).'**
  String get minDurationShowAll;

  /// No description provided for @minDurationTitle.
  ///
  /// In pt, this message translates to:
  /// **'Duração mínima'**
  String get minDurationTitle;

  /// No description provided for @minutesCount.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} minuto} other{{count} minutos}}'**
  String minutesCount(num count);

  /// No description provided for @minutesHint.
  ///
  /// In pt, this message translates to:
  /// **'Ex.: 20'**
  String get minutesHint;

  /// No description provided for @minutesLabel.
  ///
  /// In pt, this message translates to:
  /// **'Minutos'**
  String get minutesLabel;

  /// No description provided for @minutesShort.
  ///
  /// In pt, this message translates to:
  /// **'{count} min'**
  String minutesShort(int count);

  /// No description provided for @musicSearchHint.
  ///
  /// In pt, this message translates to:
  /// **'Buscar música, artista ou álbum'**
  String get musicSearchHint;

  /// No description provided for @noErrorsRecorded.
  ///
  /// In pt, this message translates to:
  /// **'Nenhum erro registrado.'**
  String get noErrorsRecorded;

  /// No description provided for @noIgnoredFolders.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma pasta ignorada'**
  String get noIgnoredFolders;

  /// No description provided for @noTrackSelected.
  ///
  /// In pt, this message translates to:
  /// **'Nenhuma faixa selecionada'**
  String get noTrackSelected;

  /// No description provided for @nowPlaying.
  ///
  /// In pt, this message translates to:
  /// **'Agora tocando'**
  String get nowPlaying;

  /// No description provided for @offOption.
  ///
  /// In pt, this message translates to:
  /// **'Desligado'**
  String get offOption;

  /// No description provided for @openSettingsBtn.
  ///
  /// In pt, this message translates to:
  /// **'Abrir ajustes'**
  String get openSettingsBtn;

  /// No description provided for @pause.
  ///
  /// In pt, this message translates to:
  /// **'Pausar'**
  String get pause;

  /// No description provided for @pauseOnNoisySubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Ao tirar o fone (com fio ou Bluetooth), a música pausa — sem retomada automática.'**
  String get pauseOnNoisySubtitle;

  /// No description provided for @pauseOnNoisyTitle.
  ///
  /// In pt, this message translates to:
  /// **'Pausar ao desconectar fones'**
  String get pauseOnNoisyTitle;

  /// No description provided for @permissionAllow.
  ///
  /// In pt, this message translates to:
  /// **'Permita o acesso às músicas para ver sua biblioteca.'**
  String get permissionAllow;

  /// No description provided for @permissionBlocked.
  ///
  /// In pt, this message translates to:
  /// **'Permissão bloqueada. Libere nas Configurações do sistema para ver suas músicas.'**
  String get permissionBlocked;

  /// No description provided for @permAllFiles.
  ///
  /// In pt, this message translates to:
  /// **'Todos os arquivos'**
  String get permAllFiles;

  /// No description provided for @permAllFilesSub.
  ///
  /// In pt, this message translates to:
  /// **'Listar PDFs no Android 13+ (acesso especial do sistema).'**
  String get permAllFilesSub;

  /// No description provided for @permMusic.
  ///
  /// In pt, this message translates to:
  /// **'Músicas'**
  String get permMusic;

  /// No description provided for @permNotifications.
  ///
  /// In pt, this message translates to:
  /// **'Notificações'**
  String get permNotifications;

  /// No description provided for @permNotificationsSub.
  ///
  /// In pt, this message translates to:
  /// **'Notificação de música na tela de bloqueio (Android 13+).'**
  String get permNotificationsSub;

  /// No description provided for @permPhotos.
  ///
  /// In pt, this message translates to:
  /// **'Fotos'**
  String get permPhotos;

  /// No description provided for @permVideos.
  ///
  /// In pt, this message translates to:
  /// **'Vídeos'**
  String get permVideos;

  /// No description provided for @play.
  ///
  /// In pt, this message translates to:
  /// **'Tocar'**
  String get play;

  /// No description provided for @playGroupTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Tocar grupo'**
  String get playGroupTooltip;

  /// No description provided for @playingNow.
  ///
  /// In pt, this message translates to:
  /// **'Tocando agora'**
  String get playingNow;

  /// No description provided for @previous.
  ///
  /// In pt, this message translates to:
  /// **'Anterior'**
  String get previous;

  /// No description provided for @queueAppend.
  ///
  /// In pt, this message translates to:
  /// **'Adicionar à fila'**
  String get queueAppend;

  /// No description provided for @queueEmpty.
  ///
  /// In pt, this message translates to:
  /// **'Fila vazia — use \"Tocar a seguir\" ou \"Adicionar à fila\" no menu de uma música.'**
  String get queueEmpty;

  /// No description provided for @queueHeader.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} faixa • toque para tocar, segure o alça para reordenar} other{{count} faixas • toque para tocar, segure o alça para reordenar}}'**
  String queueHeader(num count);

  /// No description provided for @queuePlayNext.
  ///
  /// In pt, this message translates to:
  /// **'Tocar a seguir'**
  String get queuePlayNext;

  /// No description provided for @queueTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Fila de reprodução'**
  String get queueTooltip;

  /// No description provided for @recheckTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Verificar novamente'**
  String get recheckTooltip;

  /// No description provided for @removeFromListTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Remover da lista'**
  String get removeFromListTooltip;

  /// No description provided for @removeFromQueue.
  ///
  /// In pt, this message translates to:
  /// **'Remover da fila'**
  String get removeFromQueue;

  /// No description provided for @repeat.
  ///
  /// In pt, this message translates to:
  /// **'Repetir'**
  String get repeat;

  /// No description provided for @resumePlaybackSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Ao abrir o app, retoma a última música e posição.'**
  String get resumePlaybackSubtitle;

  /// No description provided for @resumePlaybackTitle.
  ///
  /// In pt, this message translates to:
  /// **'Continuar de onde parou'**
  String get resumePlaybackTitle;

  /// No description provided for @schedule.
  ///
  /// In pt, this message translates to:
  /// **'Agendar'**
  String get schedule;

  /// No description provided for @secondsShort.
  ///
  /// In pt, this message translates to:
  /// **'{count} s'**
  String secondsShort(int count);

  /// No description provided for @selectedCount.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} selecionada} other{{count} selecionadas}}'**
  String selectedCount(num count);

  /// No description provided for @settingsAbout.
  ///
  /// In pt, this message translates to:
  /// **'Sobre'**
  String get settingsAbout;

  /// No description provided for @settingsBackground.
  ///
  /// In pt, this message translates to:
  /// **'Segundo plano'**
  String get settingsBackground;

  /// No description provided for @settingsLibrary.
  ///
  /// In pt, this message translates to:
  /// **'Biblioteca'**
  String get settingsLibrary;

  /// No description provided for @settingsPermissions.
  ///
  /// In pt, this message translates to:
  /// **'Permissões'**
  String get settingsPermissions;

  /// No description provided for @settingsPlayback.
  ///
  /// In pt, this message translates to:
  /// **'Reprodução'**
  String get settingsPlayback;

  /// No description provided for @settingsTrash.
  ///
  /// In pt, this message translates to:
  /// **'Lixeira'**
  String get settingsTrash;

  /// No description provided for @share.
  ///
  /// In pt, this message translates to:
  /// **'Compartilhar'**
  String get share;

  /// No description provided for @shareApps.
  ///
  /// In pt, this message translates to:
  /// **'WhatsApp, Messenger e outros'**
  String get shareApps;

  /// No description provided for @shareSelected.
  ///
  /// In pt, this message translates to:
  /// **'Compartilhar selecionadas'**
  String get shareSelected;

  /// No description provided for @shuffleTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Embaralhar'**
  String get shuffleTooltip;

  /// No description provided for @skippedKept.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} faixa embutida no app foi mantida.} other{{count} faixas embutidas no app foram mantidas.}}'**
  String skippedKept(num count);

  /// No description provided for @sleepActiveUntilEnd.
  ///
  /// In pt, this message translates to:
  /// **'Dormindo ao fim da faixa'**
  String get sleepActiveUntilEnd;

  /// No description provided for @sleepActiveIn.
  ///
  /// In pt, this message translates to:
  /// **'Dormindo em {time}'**
  String sleepActiveIn(String time);

  /// No description provided for @sleepChipUntilEnd.
  ///
  /// In pt, this message translates to:
  /// **'Dormir ao fim da faixa'**
  String get sleepChipUntilEnd;

  /// No description provided for @sleepChipIn.
  ///
  /// In pt, this message translates to:
  /// **'Dormir em {time}'**
  String sleepChipIn(String time);

  /// No description provided for @sleepFadeNote.
  ///
  /// In pt, this message translates to:
  /// **'O áudio dá fade e para sozinho.'**
  String get sleepFadeNote;

  /// No description provided for @sleepTimerTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Timer de sono'**
  String get sleepTimerTooltip;

  /// No description provided for @speedTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Velocidade {speed}x'**
  String speedTooltip(String speed);

  /// No description provided for @sortAscendingOption.
  ///
  /// In pt, this message translates to:
  /// **'Ordem crescente'**
  String get sortAscendingOption;

  /// No description provided for @sortDescendingOption.
  ///
  /// In pt, this message translates to:
  /// **'Ordem decrescente'**
  String get sortDescendingOption;

  /// No description provided for @sortKeyAlbum.
  ///
  /// In pt, this message translates to:
  /// **'Álbum'**
  String get sortKeyAlbum;

  /// No description provided for @sortKeyArtist.
  ///
  /// In pt, this message translates to:
  /// **'Artista'**
  String get sortKeyArtist;

  /// No description provided for @sortKeyDateAdded.
  ///
  /// In pt, this message translates to:
  /// **'Data de adição'**
  String get sortKeyDateAdded;

  /// No description provided for @sortKeyDuration.
  ///
  /// In pt, this message translates to:
  /// **'Duração'**
  String get sortKeyDuration;

  /// No description provided for @sortKeyMostPlayed.
  ///
  /// In pt, this message translates to:
  /// **'Mais tocadas'**
  String get sortKeyMostPlayed;

  /// No description provided for @sortKeyTitle.
  ///
  /// In pt, this message translates to:
  /// **'Título'**
  String get sortKeyTitle;

  /// No description provided for @sortTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Ordenar'**
  String get sortTooltip;

  /// No description provided for @themeDark.
  ///
  /// In pt, this message translates to:
  /// **'Escuro'**
  String get themeDark;

  /// No description provided for @themeLight.
  ///
  /// In pt, this message translates to:
  /// **'Claro'**
  String get themeLight;

  /// No description provided for @trackActionsTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Ações da faixa'**
  String get trackActionsTooltip;

  /// No description provided for @trashExpiresIn.
  ///
  /// In pt, this message translates to:
  /// **'{days, plural, one{O que for excluído hoje será apagado em {days} dia.} other{O que for excluído hoje será apagado em {days} dias.}}'**
  String trashExpiresIn(num days);

  /// No description provided for @trashForeverSub.
  ///
  /// In pt, this message translates to:
  /// **'Nada é apagado sozinho; você esvazia manualmente.'**
  String get trashForeverSub;

  /// No description provided for @trashRetentionSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Itens excluídos ficam na lixeira por {label}.\nDepois disso são apagados sozinhos, sem aviso — o resto fica disponível em Arquivos → Mais opções → Lixeira.'**
  String trashRetentionSubtitle(String label);

  /// No description provided for @trashRetentionTitle.
  ///
  /// In pt, this message translates to:
  /// **'Prazo de exclusão'**
  String get trashRetentionTitle;

  /// No description provided for @tracksCount.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} faixa} other{{count} faixas}}'**
  String tracksCount(num count);

  /// No description provided for @unfavorite.
  ///
  /// In pt, this message translates to:
  /// **'Desfavoritar'**
  String get unfavorite;

  /// No description provided for @viewTrashSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Restaurar ou apagar definitivamente'**
  String get viewTrashSubtitle;

  /// No description provided for @viewTrashTitle.
  ///
  /// In pt, this message translates to:
  /// **'Ver lixeira'**
  String get viewTrashTitle;

  /// No description provided for @daysCount.
  ///
  /// In pt, this message translates to:
  /// **'{count, plural, one{{count} dia} other{{count} dias}}'**
  String daysCount(num count);

  /// No description provided for @assetLockedMessage.
  ///
  /// In pt, this message translates to:
  /// **'Faixa embutida no app, não pode ser excluída.'**
  String get assetLockedMessage;

  /// No description provided for @optionSystem.
  ///
  /// In pt, this message translates to:
  /// **'Sistema'**
  String get optionSystem;

  /// No description provided for @addedUpNext.
  ///
  /// In pt, this message translates to:
  /// **'A seguir: {title}'**
  String addedUpNext(String title);

  /// No description provided for @addedInQueue.
  ///
  /// In pt, this message translates to:
  /// **'Na fila: {title}'**
  String addedInQueue(String title);

  /// No description provided for @shareAssetSub.
  ///
  /// In pt, this message translates to:
  /// **'Faixa embutida no app: não é um arquivo'**
  String get shareAssetSub;

  /// No description provided for @timerRangeError.
  ///
  /// In pt, this message translates to:
  /// **'Informe um número de 1 a 720.'**
  String get timerRangeError;

  /// No description provided for @cancelTimer.
  ///
  /// In pt, this message translates to:
  /// **'Desligar timer'**
  String get cancelTimer;

  /// No description provided for @next.
  ///
  /// In pt, this message translates to:
  /// **'Próxima'**
  String get next;

  /// No description provided for @lyricsTooltip.
  ///
  /// In pt, this message translates to:
  /// **'Letras'**
  String get lyricsTooltip;

  /// No description provided for @amoledTitle.
  ///
  /// In pt, this message translates to:
  /// **'Tema escuro AMOLED'**
  String get amoledTitle;

  /// No description provided for @amoledSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Preto puro nos fundos do modo escuro — só tem efeito com o tema escuro ligado.'**
  String get amoledSubtitle;

  /// No description provided for @defaultSpeedTitle.
  ///
  /// In pt, this message translates to:
  /// **'Velocidade padrão'**
  String get defaultSpeedTitle;

  /// No description provided for @defaultSpeedSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Vale para toda a reprodução e volta no próximo boot.'**
  String get defaultSpeedSubtitle;

  /// No description provided for @sleepDefaultTitle.
  ///
  /// In pt, this message translates to:
  /// **'Timer de sono padrão'**
  String get sleepDefaultTitle;

  /// No description provided for @sleepDefaultSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Atalho no topo do menu do sono: agenda sem escolher de novo.'**
  String get sleepDefaultSubtitle;

  /// No description provided for @sleepDefaultLabel.
  ///
  /// In pt, this message translates to:
  /// **'Padrão do timer'**
  String get sleepDefaultLabel;

  /// No description provided for @stopPausedTitle.
  ///
  /// In pt, this message translates to:
  /// **'Parar serviço após pausar'**
  String get stopPausedTitle;

  /// No description provided for @stopPausedSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Encerra o player depois de N minutos pausado (0 = nunca).'**
  String get stopPausedSubtitle;

  /// No description provided for @defaultSortTitle.
  ///
  /// In pt, this message translates to:
  /// **'Ordenação padrão'**
  String get defaultSortTitle;

  /// No description provided for @defaultSortSubtitle.
  ///
  /// In pt, this message translates to:
  /// **'Como a lista de músicas é ordenada ao abrir o app.'**
  String get defaultSortSubtitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
