// Item 6.2 — estados de tela do gerenciador extraídos de
// lib/screens/files_screen.dart (acesso "Todos os arquivos" e vazio).

import 'package:flutter/material.dart';

// =============================================================================
// ESTADOS VAZIOS / PERMISSÃO
// =============================================================================

class AllFilesAccessState extends StatelessWidget {
  final VoidCallback onRequest;

  const AllFilesAccessState({super.key, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 64, color: colors.outline),
            const SizedBox(height: 12),
            Text(
              'O Audify precisa do acesso especial "Todos os arquivos" '
              'para funcionar como gerenciador de arquivos.\n\n'
              'Na tela do sistema que abrir, ative o acesso para este app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Conceder acesso'),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
