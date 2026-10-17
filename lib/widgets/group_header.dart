// Item 6.2 — linha e cabeçalho do modo agrupado da aba Música, extraídos de
// lib/screens/music_screen.dart.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../providers/player_provider.dart';
import '../utils/motion.dart';

/// Linha achatada do modo agrupado (item 2.2): cabeçalho
/// (indexInGroup < 0) ou faixa do grupo (indexInGroup >= 0 — a faixa
/// mora em group.songs[indexInGroup]).
class GroupRow {
  final SongGroup group;
  final int indexInGroup;

  GroupRow.header(this.group) : indexInGroup = -1;

  GroupRow.item(this.group, this.indexInGroup);
}

/// Cabeçalho de grupo (Álbum/Artista/Pasta): expande/recolhe e toca o
/// grupo inteiro.
class GroupHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onPlayAll;

  const GroupHeader({super.key, 
    required this.icon,
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    required this.onPlayAll,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final AppLocalizations l10n = l10nOf(context);

    return ListTile(
      leading: Icon(icon, color: colors.primary),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(l10n.tracksCount(count)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.playGroupTooltip,
            icon: const Icon(Icons.play_circle_outline),
            onPressed: onPlayAll,
          ),
          AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: Motion.scale(context, Motion.fast),
            child: IconButton(
              tooltip: collapsed ? l10n.expandTooltip : l10n.collapseTooltip,
              icon: const Icon(Icons.expand_more),
              onPressed: onToggle,
            ),
          ),
        ],
      ),
      onTap: onToggle,
    );
  }
}
