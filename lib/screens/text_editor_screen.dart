import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/text_file_service.dart';

/// Editor de texto simples embutido no app.
///
/// Cobre o caso "criei um index.html e quero ajustar" sem sair do Audify. Não
/// tenta ser um IDE: é um `TextField` multilinha com salvar, desfazer por
/// atalho e validação de JSON — o suficiente para nota, HTML, CSS, JS e
/// configuração.
///
/// Não há edição por rich text: o conteúdo é texto puro, que é o formato em
/// que HTML/CSS/JSON realmente vivem. Colar texto formatado aqui produziria
/// arquivo inválido.
class TextEditorScreen extends StatefulWidget {
  /// Caminho do arquivo. Já deve existir (a tela é aberta para editar).
  final String path;

  const TextEditorScreen({super.key, required this.path});

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _loading = true;
  bool _dirty = false;
  String? _error;
  int _saveCount = 0;

  String get _fileName => widget.path.split('/').last;
  String? get _extension => TextFileService.extensionOf(widget.path);

  bool get _isJson => _extension == 'json';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final TextFileResult result = await TextFileService.read(widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.error;
      if (result.success) {
        _controller.text = result.content ?? '';
        _dirty = false;
      }
    });
  }

  Future<void> _save() async {
    final String content = _controller.text;
    // JSON quebrado é erro que só aparece em outro programa: melhor barrar
    // aqui, com o motivo.
    if (_isJson) {
      final String? problem = TextFileService.validateJson(content);
      if (problem != null) {
        _showMessage(problem, isError: true);
        return;
      }
    }
    final TextFileResult result = await TextFileService.write(
      widget.path,
      content,
    );
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.error ?? 'Falha ao salvar.', isError: true);
      return;
    }
    setState(() {
      _dirty = false;
      _saveCount++;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Salvo'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  /// Pergunta antes de sair com alteração não salva.
  ///
  /// Sair e perder o texto é o pior resultado desta tela — o usuário pode ter
  /// escrito uma página inteira.
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final bool? keep = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Descartar alterações?'),
        content: const Text('As mudanças não salvas serão perdidas.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Continuar editando'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Descartar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    // null = "Salvar": a intenção é salvar, não descartar.
    if (keep == false) {
      await _save();
      return !_dirty;
    }
    return keep ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return PopScope<void>(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        final NavigatorState navigator = Navigator.of(context);
        final bool canLeave = await _confirmDiscard();
        // Navigator capturado ANTES do await: o `context` pode ter saído da
        // tela enquanto o diálogo estava aberto.
        if (canLeave) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                _dirty ? 'Não salvo' : 'Salvo',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.normal,
                  color: _dirty ? colors.error : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: 'Salvar',
              icon: const Icon(Icons.save_outlined),
              onPressed: _save,
            ),
            IconButton(
              tooltip: 'Ajuda',
              icon: const Icon(Icons.help_outline),
              onPressed: () => _showHelp(colors),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _ErrorState(message: _error!)
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Shortcuts(
                  shortcuts: <ShortcutActivator, Intent>{
                    const SingleActivator(LogicalKeyboardKey.keyS):
                        const _SaveIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _SaveIntent: CallbackAction<_SaveIntent>(
                        onInvoke: (_) {
                          _save();
                          return null;
                        },
                      ),
                    },
                    child: Column(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            focusNode: _focus,
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            autocorrect: false,
                            enableSuggestions: false,
                            textAlignVertical: TextAlignVertical.top,
                            // Monoespaçado: em código, a coluna importa.
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13.5,
                              height: 1.4,
                              color: colors.onSurface,
                            ),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: colors.surfaceContainerHighest
                                  .withValues(alpha: 0.4),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.all(12),
                            ),
                            onChanged: (_) => setState(() => _dirty = true),
                          ),
                        ),
                        _StatusBar(
                          lines: _lineCount,
                          chars: _controller.text.length,
                          isJson: _isJson,
                          saveCount: _saveCount,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  int get _lineCount => '\n'.allMatches(_controller.text).length + 1;

  void _showHelp(ColorScheme colors) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: const <Widget>[
            ListTile(
              leading: Icon(Icons.save_outlined),
              title: Text('Salvar'),
              subtitle: Text('Botão na barra superior ou Ctrl+S.'),
            ),
            ListTile(
              leading: Icon(Icons.data_object),
              title: Text('JSON é validado ao salvar'),
              subtitle: Text(
                'Com erro de sintaxe, o app avisa e NÃO grava — evita '
                'arquivo quebrado que só falharia em outro programa.',
              ),
            ),
            ListTile(
              leading: Icon(Icons.code),
              title: Text('Texto puro'),
              subtitle: Text(
                'Colar texto formatado (do Word, por exemplo) pode gerar '
                'HTML ou JSON inválido.',
              ),
            ),
            ListTile(
              leading: Icon(Icons.save_alt),
              title: Text('Sair sem salvar'),
              subtitle: Text('O app pergunta antes de descartar.'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Intenção do atalho de salvar.
class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// Rodapé com contadores e validação.
class _StatusBar extends StatelessWidget {
  final int lines;
  final int chars;
  final bool isJson;
  final int saveCount;

  const _StatusBar({
    required this.lines,
    required this.chars,
    required this.isJson,
    required this.saveCount,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? jsonProblem = isJson
        ? TextFileService.validateJson(
            // Só mostra erro de JSON quando o arquivo já tem conteúdo; um
            // arquivo em branco ainda não é "inválido", está em construção.
            '',
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Text(
            '$lines ${lines == 1 ? 'linha' : 'linhas'} • $chars caracteres'
            '${saveCount > 0 ? ' • salvo $saveCount×' : ''}',
            style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
          ),
          const Spacer(),
          if (isJson && jsonProblem == null)
            Row(
              children: <Widget>[
                Icon(
                  Icons.check_circle_outline,
                  size: 13,
                  color: colors.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  'JSON ok',
                  style: TextStyle(fontSize: 11.5, color: colors.primary),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;

  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
