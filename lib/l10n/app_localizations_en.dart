// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Audify';

  @override
  String get aboutSubtitle =>
      'Local media player — music, videos, photos and PDFs.\nMade by GpWebSolution';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get addButton => 'Add';

  @override
  String addedManyToPlaylist(num count, Object name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count added to \"$name\"',
      one: '$count added to \"$name\"',
    );
    return '$_temp0';
  }

  @override
  String addedPartialToPlaylist(int added, int total, String name) {
    return '$added of $total added to \"$name\"';
  }

  @override
  String addedToPlaylist(String name) {
    return 'Added to \"$name\"';
  }

  @override
  String get addToPlaylist => 'Add to playlist';

  @override
  String get allowBtn => 'Allow';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get atTrackEnd => 'At track end';

  @override
  String get atTrackEndSub =>
      'Stops at the end of this track, without skipping to the next';

  @override
  String get batterySub =>
      'Recommended: without it, Xiaomi/Samsung/Motorola may stop music in the background.';

  @override
  String get batteryTitle => 'Ignore battery optimization';

  @override
  String get cancel => 'Cancel';

  @override
  String get clearButton => 'Clear';

  @override
  String get clearSearchTooltip => 'Clear search';

  @override
  String get closeButton => 'Close';

  @override
  String get collapseTooltip => 'Collapse';

  @override
  String get crossfadeDirect => 'Direct track change (default).';

  @override
  String crossfadeOverlap(int n) {
    return 'During the last ${n}s of the track and the first ${n}s of the next, the volume crossfades.';
  }

  @override
  String get crossfadeSubtitle =>
      'Smooth transition between tracks — the current fades out while the next fades in (no gap).';

  @override
  String get crossfadeTitle => 'Crossfade';

  @override
  String get customSleep => 'Custom';

  @override
  String get customSleepSub => 'From 1 to 720 minutes';

  @override
  String get customTimerTitle => 'Custom timer';

  @override
  String get deleteFromDevice => 'Delete from device';

  @override
  String deleteSubtitle(String title) {
    return '$title • Android will ask for confirmation';
  }

  @override
  String get deleteTrackGoneSub => 'Leaves the list, queue and playlists';

  @override
  String get details => 'Details';

  @override
  String get detailsSub => 'Album, artist, size and path';

  @override
  String get emptyNoMusic =>
      'No music found.\nAdd .mp3 files to assets/songs/ or on the device.';

  @override
  String emptyNoResults(String query) {
    return 'No results for \"$query\".';
  }

  @override
  String get emptyPermissionDenied =>
      'Music access permission denied.\nAllow it above to see the device\'s music.';

  @override
  String get equalizerSettingsSubtitle => 'Bands, presets and bass boost.';

  @override
  String get equalizerSheetSubtitle => 'Bands, presets and bass boost';

  @override
  String get equalizerTitle => 'Equalizer';

  @override
  String get errorLogSub => 'Local diagnostics (stays on the device).';

  @override
  String get errorLogTitle => 'Error log';

  @override
  String get expandTooltip => 'Expand';

  @override
  String get favorite => 'Favorite';

  @override
  String get favoriteOffSub => 'Leaves the Favorites playlist';

  @override
  String get favoriteOnSub => 'Adds to the Favorites playlist';

  @override
  String get foreverOption => 'Forever';

  @override
  String get groupAlbum => 'Album';

  @override
  String get groupArtist => 'Artist';

  @override
  String get groupFolder => 'Folder';

  @override
  String get groupTracks => 'Tracks';

  @override
  String ignoredFoldersCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count folders out of the library.',
      one: '$count folder out of the library.',
    );
    return '$_temp0';
  }

  @override
  String get ignoredFoldersEmptySub =>
      'None. WhatsApp audios/ringtones stay mixed in if the MediaStore tags them as music.';

  @override
  String get ignoredFoldersSheetSub =>
      'Tracks INSIDE the folder disappear from the library. Paste the folder path (subfolders count).';

  @override
  String get ignoredFoldersTitle => 'Ignored folders';

  @override
  String get invertSelection => 'Invert selection';

  @override
  String get languageEnglish => 'English';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Language';

  @override
  String get licensesSub => 'Libraries used in the app.';

  @override
  String get licensesTitle => 'Open-source licenses';

  @override
  String get minDurationAll => 'All tracks appear (default).';

  @override
  String minDurationHide(String label) {
    return 'Hides tracks shorter than $label — beeps and notifications disappear.';
  }

  @override
  String minDurationHideShort(String label) {
    return 'Hides from the catalog anything under $label — short beeps and notifications vanish.';
  }

  @override
  String get minDurationShowAll => 'Shows all tracks (default).';

  @override
  String get minDurationTitle => 'Minimum duration';

  @override
  String minutesCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '$count minute',
    );
    return '$_temp0';
  }

  @override
  String get minutesHint => 'e.g. 20';

  @override
  String get minutesLabel => 'Minutes';

  @override
  String minutesShort(int count) {
    return '$count min';
  }

  @override
  String get musicSearchHint => 'Search song, artist or album';

  @override
  String get noErrorsRecorded => 'No errors recorded.';

  @override
  String get noIgnoredFolders => 'No ignored folders';

  @override
  String get noTrackSelected => 'No track selected';

  @override
  String get nowPlaying => 'Now playing';

  @override
  String get offOption => 'Off';

  @override
  String get openSettingsBtn => 'Open settings';

  @override
  String get pause => 'Pause';

  @override
  String get pauseOnNoisySubtitle =>
      'When you unplug (wired or Bluetooth), music pauses — no auto resume.';

  @override
  String get pauseOnNoisyTitle => 'Pause when headphones disconnect';

  @override
  String get permissionAllow => 'Allow music access to see your library.';

  @override
  String get permissionBlocked =>
      'Permission blocked. Release it in the system Settings to see your music.';

  @override
  String get permAllFiles => 'All files';

  @override
  String get permAllFilesSub =>
      'List PDFs on Android 13+ (special system access).';

  @override
  String get permMusic => 'Music';

  @override
  String get permNotifications => 'Notifications';

  @override
  String get permNotificationsSub =>
      'Music notification on the lock screen (Android 13+).';

  @override
  String get permPhotos => 'Photos';

  @override
  String get permVideos => 'Videos';

  @override
  String get play => 'Play';

  @override
  String get playGroupTooltip => 'Play group';

  @override
  String get playingNow => 'Playing now';

  @override
  String get previous => 'Previous';

  @override
  String get queueAppend => 'Add to queue';

  @override
  String get queueEmpty =>
      'Empty queue — use \"Play next\" or \"Add to queue\" in a song\'s menu.';

  @override
  String queueHeader(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks • tap to play, hold the handle to reorder',
      one: '$count track • tap to play, hold the handle to reorder',
    );
    return '$_temp0';
  }

  @override
  String get queuePlayNext => 'Play next';

  @override
  String get queueTooltip => 'Playback queue';

  @override
  String get recheckTooltip => 'Check again';

  @override
  String get removeFromListTooltip => 'Remove from list';

  @override
  String get removeFromQueue => 'Remove from queue';

  @override
  String get repeat => 'Repeat';

  @override
  String get resumePlaybackSubtitle =>
      'On open, resumes the last song and position.';

  @override
  String get resumePlaybackTitle => 'Resume where you left off';

  @override
  String get schedule => 'Schedule';

  @override
  String secondsShort(int count) {
    return '$count s';
  }

  @override
  String selectedCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '$count selected',
    );
    return '$_temp0';
  }

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsBackground => 'Background';

  @override
  String get settingsLibrary => 'Library';

  @override
  String get settingsPermissions => 'Permissions';

  @override
  String get settingsPlayback => 'Playback';

  @override
  String get settingsTrash => 'Trash';

  @override
  String get share => 'Share';

  @override
  String get shareApps => 'WhatsApp, Messenger and others';

  @override
  String get shareSelected => 'Share selected';

  @override
  String get shuffleTooltip => 'Shuffle';

  @override
  String skippedKept(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count built-in tracks were kept in the app.',
      one: '$count built-in track was kept in the app.',
    );
    return '$_temp0';
  }

  @override
  String get sleepActiveUntilEnd => 'Falling asleep at track end';

  @override
  String sleepActiveIn(String time) {
    return 'Sleeping in $time';
  }

  @override
  String get sleepChipUntilEnd => 'Sleep at track end';

  @override
  String sleepChipIn(String time) {
    return 'Sleep in $time';
  }

  @override
  String get sleepFadeNote => 'Audio fades out and stops by itself.';

  @override
  String get sleepTimerTooltip => 'Sleep timer';

  @override
  String speedTooltip(String speed) {
    return 'Speed ${speed}x';
  }

  @override
  String get sortAscendingOption => 'Ascending';

  @override
  String get sortDescendingOption => 'Descending';

  @override
  String get sortKeyAlbum => 'Album';

  @override
  String get sortKeyArtist => 'Artist';

  @override
  String get sortKeyDateAdded => 'Date added';

  @override
  String get sortKeyDuration => 'Duration';

  @override
  String get sortKeyMostPlayed => 'Most played';

  @override
  String get sortKeyTitle => 'Title';

  @override
  String get sortTooltip => 'Sort';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeLight => 'Light';

  @override
  String get trackActionsTooltip => 'Track actions';

  @override
  String trashExpiresIn(num days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Items deleted today will be auto-deleted in $days days.',
      one: 'Items deleted today will be auto-deleted in $days day.',
    );
    return '$_temp0';
  }

  @override
  String get trashForeverSub =>
      'Nothing is deleted automatically; you clear it manually.';

  @override
  String trashRetentionSubtitle(String label) {
    return 'Deleted items stay in the trash for $label.\nAfter that they are deleted on their own, no warning — the rest is available in Files → More options → Trash.';
  }

  @override
  String get trashRetentionTitle => 'Deletion period';

  @override
  String tracksCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks',
      one: '$count track',
    );
    return '$_temp0';
  }

  @override
  String get unfavorite => 'Unfavorite';

  @override
  String get viewTrashSubtitle => 'Restore or permanently delete';

  @override
  String get viewTrashTitle => 'View trash';

  @override
  String daysCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '$count day',
    );
    return '$_temp0';
  }

  @override
  String get assetLockedMessage => 'Built-in track, it cannot be deleted.';

  @override
  String get optionSystem => 'System';

  @override
  String addedUpNext(String title) {
    return 'Up next: $title';
  }

  @override
  String addedInQueue(String title) {
    return 'In queue: $title';
  }

  @override
  String get shareAssetSub => 'Built-in track: not a file';

  @override
  String get timerRangeError => 'Enter a number from 1 to 720.';

  @override
  String get cancelTimer => 'Turn off timer';

  @override
  String get next => 'Next';

  @override
  String get lyricsTooltip => 'Lyrics';

  @override
  String get amoledTitle => 'AMOLED dark theme';

  @override
  String get amoledSubtitle =>
      'Pure black backgrounds in dark mode — only applies while the dark theme is on.';

  @override
  String get defaultSpeedTitle => 'Default speed';

  @override
  String get defaultSpeedSubtitle =>
      'Applies to all playback and is restored on the next boot.';

  @override
  String get sleepDefaultTitle => 'Default sleep timer';

  @override
  String get sleepDefaultSubtitle =>
      'Shortcut at the top of the sleep menu: schedule without choosing again.';

  @override
  String get sleepDefaultLabel => 'Timer default';

  @override
  String get stopPausedTitle => 'Stop service after pausing';

  @override
  String get stopPausedSubtitle =>
      'Stops the player after N minutes paused (0 = never).';

  @override
  String get defaultSortTitle => 'Default sort';

  @override
  String get defaultSortSubtitle =>
      'How the song list is ordered when the app opens.';

  @override
  String get seekLabel => 'Playback position';

  @override
  String get emptyPlaylists => 'No playlists yet.';

  @override
  String get newPlaylistBtn => 'New playlist';

  @override
  String get rescanBtn => 'Refresh';
}
