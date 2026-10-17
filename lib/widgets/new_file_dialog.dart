// Item 6.2 — diálogo "novo arquivo de texto" extraído de
// lib/screens/files_screen.dart.

import 'package:flutter/material.dart';

import '../services/text_file_service.dart';

/// Diálogo "novo arquivo de texto".
///
/// A extensão é escolhida por um seletor em vez de ser digitada: os tipos
/// aceitos são poucos, e digitar ".htlm" e errar numa lista livre seria
/// descobrir o problema só ao abrir o arquivo em outro programa.
class NewFileDialog extends StatefulWidget {
  const NewFileDialog({super.key});

  @override
  State<NewFileDialog> createState() => NewFileDialogState();
}

class NewFileDialogState extends State<NewFileDialog> {
  final TextEditingController _name = TextEditingController();
  String _extension = 'html';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String fullName = '${_name.text.trim()}.$_extension';
    final String? problem = TextFileService.validateName(fullName);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, fullName);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Novo arquivo de texto'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.none,
                  decoration: const InputDecoration(
                    labelText: 'Nome',
                    hintText: 'index',
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _extension,
                underline: const SizedBox.shrink(),
                items: <DropdownMenuItem<String>>[
                  for (final String ext in TextFileService.textExtensions)
                    DropdownMenuItem<String>(value: ext, child: Text('.$ext')),
                ],
                onChanged: (String? value) {
                  if (value == null) return;
                  setState(() {
                    _extension = value;
                    _error = null;
                  });
                },
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Criar e editar')),
      ],
    );
  }
}
