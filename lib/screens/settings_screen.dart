import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/error_log_service.dart';
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

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ---- Aparência ----
        const _SectionHeader(title: 'Aparência'),
        RadioGroup<ThemeMode>(
          groupValue: settings.themeMode,
          onChanged: (mode) {
            if (mode != null) settings.setThemeMode(mode);
          },
          child: const Column(
            children: [
              RadioListTile<ThemeMode>(
                title: Text('Sistema'),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Claro'),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text('Escuro'),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),

        // ---- Reprodução ----
        const _SectionHeader(title: 'Reprodução'),
        SwitchListTile(
          secondary: const Icon(Icons.history),
          title: const Text('Continuar de onde parou'),
          subtitle: const Text(
            'Ao abrir o app, retoma a última música e posição.',
          ),
          value: settings.resumePlayback,
          onChanged: settings.setResumePlayback,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.headphones_outlined),
          title: const Text('Pausar ao desconectar fones'),
          subtitle: const Text(
            'Ao tirar o fone (com fio ou Bluetooth), a música '
            'pausa — sem retomada automática.',
          ),
          value: settings.pauseOnNoisy,
          onChanged: settings.setPauseOnNoisy,
        ),

        // ---- Biblioteca (item 2.5) ----
        const _SectionHeader(title: 'Biblioteca'),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Duração mínima'),
          subtitle: Text(
            settings.libraryMinDurationSeconds == 0
                ? 'Mostra todas as faixas (padrão).'
                : 'Esconde faixas com menos de '
                    '${settings.libraryMinDurationLabel} — '
                    'toques e notificações somem.',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(settings.libraryMinDurationLabel),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => _pickMinDuration(context, settings),
        ),
        ListTile(
          leading: const Icon(Icons.folder_off),
          title: const Text('Pastas ignoradas'),
          subtitle: Text(
            settings.ignoredFolders.isEmpty
                ? 'Nenhuma. Áudios de WhatsApp/toques ficam misturados '
                    'se o MediaStore marcar como música.'
                : '${settings.ignoredFolders.length} '
                    '${settings.ignoredFolders.length == 1 ? 'pasta' : 'pastas'} '
                    'fora da biblioteca.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editIgnoredFolders(context, settings),
        ),

        // ---- Lixeira ----
        const _SectionHeader(title: 'Lixeira'),
        ListTile(
          leading: const Icon(Icons.auto_delete_outlined),
          title: const Text('Prazo de exclusão'),
          subtitle: Text(
            'Itens excluídos ficam na lixeira por '
            '${settings.trashRetentionLabel.toLowerCase()}.'
            '\nDepois disso são apagados sozinhos, sem aviso —'
            ' o resto fica disponível em Arquivos → Mais opções → Lixeira.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickTrashRetention(context, settings),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Ver lixeira'),
          subtitle: const Text('Restaurar ou apagar definitivamente'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(
                MaterialPageRoute<void>(builder: (_) => const TrashScreen()),
              )
              .then((_) => setState(() {})),
        ),

        // ---- Permissões (status real do sistema) ----
        _SectionHeader(
          title: 'Permissões',
          trailing: IconButton(
            tooltip: 'Verificar novamente',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _permissionTick++),
          ),
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.music_note_outlined,
          title: 'Músicas',
          check: () => PermissionService.hasAudioAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.videocam_outlined,
          title: 'Vídeos',
          check: () => PermissionService.hasVideosAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.photo_library_outlined,
          title: 'Fotos',
          check: () => PermissionService.hasPhotosAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.notifications_outlined,
          title: 'Notificações',
          subtitle: 'Notificação de música na tela de bloqueio (Android 13+).',
          check: () => PermissionService.hasNotificationAccess(),
          onTap: PermissionService.openSettings,
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.folder_open_outlined,
          title: 'Todos os arquivos',
          subtitle: 'Listar PDFs no Android 13+ (acesso especial do sistema).',
          check: () => PermissionService.hasAllFilesAccess(),
          onTap: () => PermissionService.requestAllFilesAccess(),
        ),

        // ---- Segundo plano ----
        _SectionHeader(
          title: 'Segundo plano',
          trailing: IconButton(
            tooltip: 'Verificar novamente',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _permissionTick++),
          ),
        ),
        _PermissionTile(
          tick: _permissionTick,
          icon: Icons.battery_saver_outlined,
          title: 'Ignorar otimização de bateria',
          subtitle:
              'Recomendado: sem isso, Xiaomi/Samsung/Motorola podem parar '
              'a música em segundo plano.',
          check: () => PermissionService.isIgnoringBatteryOptimizations(),
          onTap: () async {
            await PermissionService.requestIgnoreBatteryOptimizations();
            if (mounted) setState(() => _permissionTick++);
          },
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Log de erros'),
          subtitle: const Text('Diagnóstico local (fica só no aparelho).'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showErrorLog,
        ),

        // ---- Sobre ----
        const _SectionHeader(title: 'Sobre'),
        ListTile(
          leading: const Icon(Icons.music_note),
          title: const Text('Audify'),
          subtitle: Text(
            'Player de mídia local — músicas, vídeos, '
            'fotos e PDFs.\nFeito por GpWebSolution'
            '${_version != null ? '\nVersão $_version' : ''}',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('Licenças de código aberto'),
          subtitle: const Text('Bibliotecas usadas no app.'),
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
      builder: (BuildContext sheetContext) => SafeArea(
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
                      ? 'Para sempre'
                      : days == 1
                      ? '1 dia'
                      : '$days dias',
                ),
                subtitle: Text(
                  days == 0
                      ? 'Nada é apagado sozinho; você esvazia manualmente.'
                      : 'O que for excluído hoje será apagado em $days '
                            '${days == 1 ? 'dia' : 'dias'}.',
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
      ),
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
                RadioListTile<int>(
                  value: option,
                  title: Text(_durationLabel(option)),
                  subtitle: Text(
                    option == 0
                        ? 'Todas as faixas aparecem (padrão).'
                        : 'Esconde do catálogo o que tiver menos de '
                            '${_durationLabel(option)} — some com toques '
                            'e notificações curtas.',
                  ),
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
                      const Padding(
                        padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: Text(
                          'Pastas ignoradas',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
                        child: Text(
                          'Faixas DENTRO da pasta somem da biblioteca. '
                          'Cole o caminho da pasta (subpastas também '
                          'contam).',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      if (settings.ignoredFolders.isEmpty)
                        const ListTile(
                          leading: Icon(Icons.check_circle_outline),
                          title: Text('Nenhuma pasta ignorada'),
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
                            tooltip: 'Remover da lista',
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
                              child: const Text('Adicionar'),
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

  static String _durationLabel(int seconds) {
    if (seconds == 0) return 'Desligado';
    if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60} min';
    return '$seconds s';
  }

  Future<void> _showErrorLog() async {
    final String? content = await ErrorLogService.read();
    if (!mounted) return;
    final String text = content?.trim().isNotEmpty == true
        ? content!
        : 'Nenhum erro registrado.';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log de erros'),
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
            child: const Text('Limpar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
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
