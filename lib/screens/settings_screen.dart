import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/app_locale_choice.dart';
import '../models/song_sort_key.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/error_log_service.dart';
import '../screens/equalizer_screen.dart';
import '../screens/trash_screen.dart';
import '../services/permission_service.dart';

/// Aba de Configurações: tema, reprodução, permissões (com status real),
/// segundo plano (bateria) e sobre o app.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Incrementado pelo botão de atualizar para re-checar permissões
  /// (o IndexedStack mantém a aba viva — sem rebuild automático ao voltar
  /// das Configurações do sistema).
  int _permissionTick = 0;

  /// Versão do app lida do package_info_plus (evita "Versão 1.1.0" fixa).
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (mounted) setState(() => _version = info.version);
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final AppLocalizations l10n = l10nOf(context);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ---- Aparência ----
        _SectionHeader(title: l10n.appearanceTitle),
        RadioGroup<ThemeMode>(
          groupValue: settings.themeMode,
          onChanged: (mode) {
            if (mode != null) settings.setThemeMode(mode);
          },
          child: Column(
            children: [
              RadioListTile<ThemeMode>(
                title: Text(l10n.optionSystem),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text(l10n.themeLight),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text(l10n.themeDark),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),
        // Item 5.2 — preto puro nos fundos (só age no modo escuro).
        SwitchListTile(
          secondary: const Icon(Icons.contrast_outlined),
          title: Text(l10n.amoledTitle),
          subtitle: Text(l10n.amoledSubtitle),
          value: settings.themeAmoled,
          onChanged: settings.setThemeAmoled,
        ),
        // Item 5.1 — idioma: sistema (padrão) ou fixo, persistido.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.languageSection,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        RadioGroup<AppLocaleChoice>(
          groupValue: settings.localeChoice,
          onChanged: (choice) {
            if (choice != null) settings.setLocaleChoice(choice);
          },
          child: Column(
            children: [
              RadioListTile<AppLocaleChoice>(
                title: Text(l10n.optionSystem),
                value: AppLocaleChoice.system,
              ),
              RadioListTile<AppLocaleChoice>(
                // Nome do idioma no próprio idioma — não se traduz.
                title: Text(l10n.languagePortuguese),
                value: AppLocaleChoice.portuguese,
              ),
              RadioListTile<AppLocaleChoice>(
                title: Text(l10n.languageEnglish),
                value: AppLocaleChoice.english,
              ),
            ],
          ),
        ),

        // ---- Reprodução ----
        _SectionHeader(title: l10n.settingsPlayback),
        SwitchListTile(
          secondary: const Icon(Icons.history),
          title: Text(l10n.resumePlaybackTitle),
          subtitle: Text(l10n.resumePlaybackSubtitle),
          value: settings.resumePlayback,
          onChanged: settings.setResumePlayback,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.headphones_outlined),
          title: Text(l10n.pauseOnNoisyTitle),
          subtitle: Text(l10n.pauseOnNoisySubtitle),
          value: settings.pauseOnNoisy,
          onChanged: settings.setPauseOnNoisy,
        ),
        // Item 3.4 — crossfade entre faixas.
        ListTile(
          leading: const Icon(Icons.blur_on),
          title: Text(l10n.crossfadeTitle),
          subtitle: Text(l10n.crossfadeSubtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_crossfadeLabel(l10n, settings)),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickCrossfade(context, settings),
        ),
        // Item 3.3 — tela própria do equalizador.
        ListTile(
          leading: const Icon(Icons.equalizer),
          title: Text(l10n.equalizerTitle),
          subtitle: Text(l10n.equalizerSettingsSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EqualizerScreen()),
          ),
        ),
        // Item 5.2 — velocidade padrão (preferência da 3.2, agora
        // exposta aqui; aplica na hora e persiste).
        ListTile(
          leading: const Icon(Icons.speed),
          title: Text(l10n.defaultSpeedTitle),
          subtitle: Text(l10n.defaultSpeedSubtitle),
          // Item 5.2: a preferência é o que vale no boot e o
          // PlayerProvider a persiste a cada troca — exibir daqui
          // mantém a aba sem dependência de escopo extra.
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${settings.playbackSpeed}x'),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickDefaultSpeed(context),
        ),
        // Item 5.2 — atalho do timer de sono no topo do menu dele.
        ListTile(
          leading: const Icon(Icons.bedtime_outlined),
          title: Text(l10n.sleepDefaultTitle),
          subtitle: Text(l10n.sleepDefaultSubtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                settings.sleepDefaultMinutes == 0
                    ? l10n.offOption
                    : l10n.minutesCount(settings.sleepDefaultMinutes),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickSleepDefault(context, settings),
        ),
        // Item 5.2 — encerra o player depois de N minutos pausado.
        ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: Text(l10n.stopPausedTitle),
          subtitle: Text(l10n.stopPausedSubtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                settings.stopServicePausedMinutes == 0
                    ? l10n.offOption
                    : l10n.minutesCount(settings.stopServicePausedMinutes),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickStopPaused(context, settings),
        ),

        // ---- Biblioteca (item 2.5) ----
        _SectionHeader(title: l10n.settingsLibrary),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: Text(l10n.minDurationTitle),
          subtitle: Text(
            settings.libraryMinDurationSeconds == 0
                ? l10n.minDurationShowAll
                : l10n.minDurationHide(
                    _minDurationLabel(l10n, settings.libraryMinDurationSeconds),
                  ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _minDurationLabel(
                  l10n,
                  settings.libraryMinDurationSeconds,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickMinDuration(context, settings),
        ),
        ListTile(
          leading: const Icon(Icons.folder_off),
          title: Text(l10n.ignoredFoldersTitle),
          subtitle: Text(
            settings.ignoredFolders.isEmpty
                ? l10n.ignoredFoldersEmptySub
                : l10n.ignoredFoldersCount(settings.ignoredFolders.length),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editIgnoredFolders(context, settings),
        ),
        // Item 5.2 — ordenação padrão (mesma persistência da 4.3).
        ListTile(
          leading: const Icon(Icons.sort),
          title: Text(l10n.defaultSortTitle),
          subtitle: Text(
            '${l10n.sortKeyLabel(settings.sortKey)} • '
            '${settings.sortAscending ? l10n.sortAscendingOption : l10n.sortDescendingOption}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickDefaultSort(context, settings),
        ),

        // ---- Lixeira ----
        _SectionHeader(title: l10n.settingsTrash),
        ListTile(
          leading: const Icon(Icons.auto_delete_outlined),
          title: Text(l10n.trashRetentionTitle),
          subtitle: Text(
            l10n.trashRetentionSubtitle(
              _trashLabel(l10n, settings).toLowerCase(),
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickTrashRetention(context, settings),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(l10n.viewTrashTitle),
          subtitle: Text(l10n.viewTrashSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(
                MaterialPageRoute<void>(builder: (_) => const TrashScreen()),
              )
              .then((_) => setState(() {})),
        ),

        // ---- Permissões (status real do sistema) ----
        _SectionHeader(
          title: l10n.settingsPermissions,
          trailing: IconButton(
            tooltip: l10n.recheckTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _permissionTick++),
          ),
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.music_note_outlined,
          title: l10n.permMusic,
          check: () => PermissionService.hasAudioAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.videocam_outlined,
          title: l10n.permVideos,
          check: () => PermissionService.hasVideosAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.photo_library_outlined,
          title: l10n.permPhotos,
          check: () => PermissionService.hasPhotosAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.notifications_outlined,
          title: l10n.permNotifications,
          subtitle: l10n.permNotificationsSub,
          check: () => PermissionService.hasNotificationAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.folder_open_outlined,
          title: l10n.permAllFiles,
          subtitle: l10n.permAllFilesSub,
          check: () => PermissionService.hasAllFilesAccess(),
          onTap: () => PermissionService.requestAllFilesAccess(),
        ),

        // ---- Segundo plano ----
        _SectionHeader(
          title: l10n.settingsBackground,
          trailing: IconButton(
            tooltip: l10n.recheckTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _permissionTick++),
          ),
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.battery_saver_outlined,
          title: l10n.batteryTitle,
          subtitle: l10n.batterySub,
          check: () => PermissionService.isIgnoringBatteryOptimizations(),
          onTap: () async {
            await PermissionService.requestIgnoreBatteryOptimizations();
            if (mounted) setState(() => _permissionTick++);
          },
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: Text(l10n.errorLogTitle),
          subtitle: Text(l10n.errorLogSub),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showErrorLog,
        ),

        // ---- Sobre ----
        _SectionHeader(title: l10n.settingsAbout),
        ListTile(
          leading: const Icon(Icons.music_note),
          title: const Text('Audify'),
          subtitle: Text(
            '${l10n.aboutSubtitle}'
            '${_version != null ? '\n${l10n.aboutVersion(_version!)}' : ''}',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: Text(l10n.licensesTitle),
          subtitle: Text(l10n.licensesSub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Audify',
            applicationVersion: _version,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Dialog com o conteúdo do log de erros local (crash_log.txt).
  /// 100% offline — útil para diagnosticar um crash que aconteceu antes.
  /// Escolhe o prazo da lixeira.
  ///
  /// Diálogo com opções discretas em vez de slider: os valores são poucos
  /// (1, 7, 15, 30, 90 dias ou para sempre) e um controle contínuo faria o
  /// usuário acreditar numa precisão que não existe.
  Future<void> _pickTrashRetention(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final int days in SettingsProvider.trashRetentionOptions)
                RadioListTile<int>(
                  value: days,
                  // ignore: deprecated_member_use
                  groupValue: settings.trashRetentionDays,
                  title: Text(
                    days == 0
                        ? l10n.foreverOption
                        : days == 1
                        ? l10n.daysCount(1)
                        : l10n.daysCount(days),
                  ),
                  subtitle: Text(
                    days == 0
                        ? l10n.trashForeverSub
                        : l10n.trashExpiresIn(days),
                  ),
                  // ignore: deprecated_member_use
                  onChanged: (int? value) async {
                    if (value == null) return;
                    await settings.setTrashRetentionDays(value);
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    if (context.mounted) setState(() {});
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// Escolhe a duração do crossfade (item 3.4): 0 = desligado (padrão),
  /// até 12 s. O valor é lido ao vivo pelo serviço (getter), então vale
  /// na próxima transição sem reiniciar nada.
  Future<void> _pickCrossfade(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: RadioGroup<int>(
          groupValue: settings.crossfadeSeconds,
          onChanged: (int? value) async {
            if (value == null) return;
            await settings.setCrossfadeSeconds(value);
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          },
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final int option in SettingsProvider.crossfadeOptions)
                Builder(
                  builder: (BuildContext optionContext) {
                    final AppLocalizations l10n = l10nOf(optionContext);
                    return RadioListTile<int>(
                      value: option,
                      title: Text(
                        option == 0 ? l10n.offOption : l10n.secondsShort(option),
                      ),
                      subtitle: Text(
                        option == 0
                            ? l10n.crossfadeDirect
                            : l10n.crossfadeOverlap(option),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Item 5.2 — velocidade padrão: aplica no serviço na hora (o
  /// PlayerProvider também persiste na preferência).
  Future<void> _pickDefaultSpeed(BuildContext context) async {
    final PlayerProvider player = context.read<PlayerProvider>();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: RadioGroup<double>(
          groupValue: player.playbackSpeed,
          onChanged: (double? value) async {
            if (value == null) return;
            await player.setPlaybackSpeed(value);
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          },
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final double option
                  in SettingsProvider.playbackSpeedOptions)
                RadioListTile<double>(
                  value: option,
                  title: Text('${option}x'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Item 5.2 — duração padrão do timer de sono (0 = desativado).
  Future<void> _pickSleepDefault(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: RadioGroup<int>(
            groupValue: settings.sleepDefaultMinutes,
            onChanged: (int? value) async {
              if (value == null) return;
              await settings.setSleepDefaultMinutes(value);
              if (sheetContext.mounted) Navigator.pop(sheetContext);
            },
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final int option in SettingsProvider.sleepDefaultOptions)
                  RadioListTile<int>(
                    value: option,
                    title: Text(
                      option == 0 ? l10n.offOption : l10n.minutesCount(option),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Item 5.2 — minutos pausados antes de o serviço parar (0 =
  /// desativado; padrão 30).
  Future<void> _pickStopPaused(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: RadioGroup<int>(
            groupValue: settings.stopServicePausedMinutes,
            onChanged: (int? value) async {
              if (value == null) return;
              await settings.setStopServicePausedMinutes(value);
              if (sheetContext.mounted) Navigator.pop(sheetContext);
            },
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final int option in SettingsProvider.stopPausedOptions)
                  RadioListTile<int>(
                    value: option,
                    title: Text(
                      option == 0 ? l10n.offOption : l10n.minutesCount(option),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Item 5.2 — ordenação padrão da lista (critério + sentido). Os dois
  /// grupos aplicam sem fechar a folha, para combinar antes de sair.
  Future<void> _pickDefaultSort(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  l10n.defaultSortSubtitle,
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              RadioGroup<SongSortKey>(
                groupValue: settings.sortKey,
                onChanged: (SongSortKey? value) {
                  if (value == null) return;
                  settings.setSort(
                    key: value,
                    ascending: settings.sortAscending,
                  );
                },
                child: Column(
                  children: <Widget>[
                    for (final SongSortKey key in SongSortKey.values)
                      RadioListTile<SongSortKey>(
                        value: key,
                        title: Text(l10n.sortKeyLabel(key)),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              RadioGroup<bool>(
                groupValue: settings.sortAscending,
                onChanged: (bool? value) {
                  if (value == null) return;
                  settings.setSort(key: settings.sortKey, ascending: value);
                },
                child: Column(
                  children: <Widget>[
                    RadioListTile<bool>(
                      value: true,
                      title: Text(l10n.sortAscendingOption),
                    ),
                    RadioListTile<bool>(
                      value: false,
                      title: Text(l10n.sortDescendingOption),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Escolhe a duração mínima da biblioteca (item 2.5). Se o valor
  /// mudou, re-escaneia o catálogo para o filtro valer na hora.
  Future<void> _pickMinDuration(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final int before = settings.libraryMinDurationSeconds;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: RadioGroup<int>(
          groupValue: settings.libraryMinDurationSeconds,
          onChanged: (int? value) async {
            if (value == null) return;
            await settings.setLibraryMinDuration(value);
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          },
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final int option in SettingsProvider.minDurationOptions)
                Builder(
                  builder: (BuildContext optionContext) {
                    final AppLocalizations l10n = l10nOf(optionContext);
                    final String label = _minDurationLabel(l10n, option);
                    return RadioListTile<int>(
                      value: option,
                      title: Text(label),
                      subtitle: Text(
                        option == 0
                            ? l10n.minDurationAll
                            : l10n.minDurationHideShort(label),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (before == settings.libraryMinDurationSeconds) return;
    if (!context.mounted) return;
    await context.read<PlayerProvider>().rescanCatalog();
  }

  /// Editor de pastas ignoradas (item 2.5): lista + campo para colar o
  /// caminho (ex.: `/storage/emulated/0/WhatsApp/Audio`). Mudou a
  /// lista → re-escaneia o catálogo ao fechar.
  Future<void> _editIgnoredFolders(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    bool changed = false;
    final TextEditingController pathController = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (BuildContext sheetContext) => StatefulBuilder(
          builder: (BuildContext sheetContext, void Function(void Function()) setSheetState) {
            final AppLocalizations l10n = l10nOf(sheetContext);
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: Text(
                          l10n.ignoredFoldersTitle,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                        child: Text(
                          l10n.ignoredFoldersSheetSub,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (settings.ignoredFolders.isEmpty)
                        ListTile(
                          leading: const Icon(Icons.check_circle_outline),
                          title: Text(l10n.noIgnoredFolders),
                        ),
                      for (final String folder in settings.ignoredFolders)
                        ListTile(
                          leading: const Icon(Icons.folder_off),
                          title: Text(
                            folder,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: l10n.removeFromListTooltip,
                            icon: const Icon(Icons.close),
                            onPressed: () async {
                              final bool ok = await settings
                                  .removeIgnoredFolder(folder);
                              if (ok) changed = true;
                              if (sheetContext.mounted) {
                                setSheetState(() {});
                              }
                            },
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: TextField(
                                controller: pathController,
                                decoration: const InputDecoration(
                                  hintText:
                                      '/storage/.../WhatsApp/Audio',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () async {
                                final bool ok = await settings
                                    .addIgnoredFolder(pathController.text);
                                if (ok) {
                                  changed = true;
                                  pathController.clear();
                                }
                                if (sheetContext.mounted) {
                                  setSheetState(() {});
                                }
                              },
                              child: Text(l10n.addButton),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    } finally {
      pathController.dispose();
    }
    if (!changed || !context.mounted) return;
    await context.read<PlayerProvider>().rescanCatalog();
  }

  /// Rótulo da duração mínima (0 = desligado) — antes um getter pronto
  /// no provider; item 5.1: formatado na UI com as localizações.
  static String _minDurationLabel(AppLocalizations l10n, int seconds) {
    if (seconds == 0) return l10n.offOption;
    if (seconds >= 60 && seconds % 60 == 0) return l10n.minutesShort(seconds ~/ 60);
    return l10n.secondsShort(seconds);
  }

  /// Rótulo do crossfade (0 = desligado).
  static String _crossfadeLabel(AppLocalizations l10n, SettingsProvider settings) {
    final int seconds = settings.crossfadeSeconds;
    return seconds == 0 ? l10n.offOption : l10n.secondsShort(seconds);
  }

  /// Rótulo do prazo da lixeira.
  static String _trashLabel(AppLocalizations l10n, SettingsProvider settings) {
    final int days = settings.trashRetentionDays;
    if (days == 0) return l10n.foreverOption;
    if (days == 1) return l10n.daysCount(1);
    return l10n.daysCount(days);
  }

  Future<void> _showErrorLog() async {
    final AppLocalizations l10n = l10nOf(context);
    final String? content = await ErrorLogService.read();
    if (!mounted) return;
    final String text = content?.trim().isNotEmpty == true
        ? content!
        : l10n.noErrorsRecorded;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final AppLocalizations dialogL10n = l10nOf(dialogContext);
        return AlertDialog(
          title: Text(dialogL10n.errorLogTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await ErrorLogService.clear();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text(dialogL10n.clearButton),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogL10n.closeButton),
            ),
          ],
        );
      },
    );
  }
}

/// Linha de permissão com status real do sistema (futuro re-checkável).
///
/// O [check] roda no build e quando o tick muda (botão atualizar / volta
/// das Configurações). Enquanto carrega, mostra um indicador discreto —
/// nunca bloqueia a lista.
class _PermissionTile extends StatelessWidget {
  final int tick;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Future<bool> Function() check;
  final VoidCallback? onTap;

  const _PermissionTile({
    required this.tick,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.check,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return FutureBuilder<bool>(
      // tick no chave: força re-avaliação ao atualizar/voltar de settings.
      future: check(),
      key: ValueKey(tick),
      builder: (context, snapshot) {
        final Widget status;
        if (snapshot.connectionState != ConnectionState.done) {
          status = const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        } else if (snapshot.data == true) {
          status = Icon(Icons.check_circle, color: colors.primary, size: 20);
        } else {
          status = Icon(Icons.error_outline, color: colors.error, size: 20);
        }

        return ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle != null ? Text(subtitle!) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              status,
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: onTap,
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
