// Item 6.2 — cartão de permissão de áudio negada, extraído de
// lib/screens/music_screen.dart.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../providers/player_provider.dart';
import '../services/permission_service.dart';

/// Cartão de permissão negada com ação de nova tentativa / ajustes.
class PermissionBanner extends StatelessWidget {
  final PlayerProvider provider;

  const PermissionBanner({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final AppLocalizations l10n = l10nOf(context);
    final bool permanent =
        provider.permission == AudioPermissionState.permanentlyDenied;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              permanent ? l10n.permissionBlocked : l10n.permissionAllow,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: permanent
                ? PermissionService.openSettings
                : provider.requestPermissionAndReload,
            child: Text(permanent ? l10n.openSettingsBtn : l10n.allowBtn),
          ),
        ],
      ),
    );
  }
}
