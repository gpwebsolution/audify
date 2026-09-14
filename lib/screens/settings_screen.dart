import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/error_log_service.dart';
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
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    }).catchError((Object _) {});
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
