// Item 3.6 — folha de letras do PlayerScreen.
//
// Com timestamps: destaque da linha atual sincronizado com a posição
// (ValueListenableBuilder no notifier de posição — sem rebuild do
// provider inteiro a cada tick) + rolagem automática centrando a
// linha. Sem timestamps (letra embutida USLT): texto corrido, sem
// destaque.
//
// O loader é injetável ([LyricsService.forSong] por padrão) — testes
// de widget passam um duplo, como no resto do app.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../services/lyrics_service.dart';
import '../utils/lrc_parser.dart';

class LyricsSheet extends StatefulWidget {
  final Song song;

  /// Carregador das letras (padrão: disco/bundle/ID3).
  final LyricsLoader load;

  const LyricsSheet({
    super.key,
    required this.song,
    this.load = LyricsService.forSong,
  });

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  late Future<LrcLyrics?> _lyrics;

  @override
  void initState() {
    super.initState();
    _lyrics = widget.load(widget.song);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<LrcLyrics?>(
        future: _lyrics,
        builder: (BuildContext context, AsyncSnapshot<LrcLyrics?> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final LrcLyrics? lyrics = snapshot.data;
          if (lyrics == null || lyrics.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nenhuma letra encontrada para esta faixa. Coloque um '
                'arquivo .lrc com o mesmo nome do áudio na mesma pasta '
                '(ou use um MP3 com letra embutida).',
                textAlign: TextAlign.center,
              ),
            );
          }
          return _LyricsView(lyrics: lyrics);
        },
      ),
    );
  }
}

class _LyricsView extends StatefulWidget {
  final LrcLyrics lyrics;
  const _LyricsView({required this.lyrics});

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  /// Chave da linha corrente — o alvo da rolagem automática.
  final GlobalKey _currentLine = GlobalKey();
  final ScrollController _scroll = ScrollController();
  int _shownIndex = -1;

  /// Extensão média de uma linha (bodyLarge 16×1.5 + padding 12) — o
  /// chute inicial do salto; o ensureVisible do refino centraliza.
  static const double _estimatedLineExtent = 36;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return ValueListenableBuilder<Duration>(
      valueListenable: provider.positionListenable,
      builder: (BuildContext context, Duration position, _) {
        final int index = widget.lyrics.indexAt(position);
        if (index != _shownIndex) {
          _shownIndex = index;
          if (index >= 0) {
            // Pós-frame: a linha nova precisa estar na árvore antes do
            // rolamento; guardado para não rolar a cada tick.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _centerOn(index);
            });
          }
        }
        return ListView.builder(
          controller: _scroll,
          // shrinkWrap: folha curta encolhe; longa usa a altura máxima
          // do sheet e rola (limitada pelas constraints do modal).
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          itemCount: widget.lyrics.lines.length,
          itemBuilder: (BuildContext context, int i) {
            final LrcLine line = widget.lyrics.lines[i];
            final bool current = widget.lyrics.synced && i == index;
            return Padding(
              key: current ? _currentLine : null,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                widget.lyrics.synced && line.text.isEmpty ? '♪' : line.text,
                textAlign: widget.lyrics.synced
                    ? TextAlign.center
                    : TextAlign.left,
                style: current
                    ? textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colors.primary,
                      )
                    : textTheme.bodyLarge?.copyWith(
                        height: 1.5,
                        color: widget.lyrics.synced
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
              ),
            );
          },
        );
      },
    );
  }

  void _centerOn(int index) {
    if (!mounted) return;
    final BuildContext? near = _currentLine.currentContext;
    if (near != null) {
      _ensureVisible(near);
      return;
    }
    // Linha fora da viewport: a lista é LAZY (a linha nem existe na
    // árvore), então ensureVisible não tem alvo. Salta para a posição
    // ESTIMADA; no frame seguinte a linha já está perto e o refino
    // abaixo centraliza com precisão.
    final ScrollPosition? position =
        _scroll.hasClients ? _scroll.position : null;
    if (position == null) return;
    final double target =
        (index * _estimatedLineExtent - position.viewportDimension * 0.4)
            .clamp(0.0, position.maxScrollExtent);
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? refined = _currentLine.currentContext;
      if (refined != null && mounted) _ensureVisible(refined);
    });
  }

  void _ensureVisible(BuildContext target) {
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      // Um pouco acima do centro: a linha seguinte já fica à vista.
      alignment: 0.4,
    );
  }
}
