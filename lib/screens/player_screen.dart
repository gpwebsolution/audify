import 'package:flutter/material.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import '../models/media_ref.dart';
import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_service.dart';
import '../utils/format.dart';
import '../widgets/album_artwork.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import 'equalizer_screen.dart';
import 'music_screen.dart';

/// Player em tela cheia ("Agora tocando").
///
/// Responsabilidade: experiência imersiva de reprodução — capa grande,
/// título/artista, seek arrastável, tempos, shuffle/repeat e navegação de
/// fila (anterior/próximo). A leitura de estado é feita via Provider;
/// nenhuma lógica de áudio mora aqui.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// Posição em ms mantida localmente durante o arrasto do slider.
  double? _dragValueMs;

  /// Exclui a faixa em reprodução (ou explica por que ela não é excluível).
  ///
  /// A decisão de "isto é uma faixa do aparelho?" fica no modelo
  /// ([MediaRef.fromSong]); aqui só há o atalho de UI para o botão.
  Future<void> _deleteCurrent(
    BuildContext context,
    PlayerProvider provider,
    Song song,
  ) async {
    if (MediaRef.fromSong(song) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(MusicScreen.assetLockedMessage)),
      );
      return;
    }
    await MusicScreen.deleteSong(context, provider, song);
  }

  /// Menu de ações da faixa em reprodução.
  ///
  /// Reúne o que antes estava espalhado (lixeira no AppBar, "adicionar à
  /// playlist" só na lista) e adiciona o que faltava: detalhes e
  /// compartilhar. Uma entrada por ação, com o motivo desabilitado quando não
  /// se aplica — em vez de botão sumindo e o usuário sem saber que existe.
  Future<void> _showSongActions(
    BuildContext context,
    PlayerProvider provider,
    Song song,
  ) async {
    final MediaRef? ref = MediaRef.fromSong(song);
    final bool isAsset = ref == null;
    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool hasPlaylists = playlists.playlists.isNotEmpty;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        void go(Future<void> Function() action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Adicionar à playlist'),
                subtitle: hasPlaylists
                    ? null
                    : const Text('Crie uma playlist na aba Playlists'),
                enabled: hasPlaylists,
                onTap: () =>
                    go(() => _addCurrentToPlaylist(context, playlists, song)),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                subtitle: Text(
                  isAsset
                      ? 'Faixa embutida no app: não é um arquivo'
                      : 'WhatsApp, Messenger e outros',
                ),
                enabled: !isAsset,
                onTap: () => go(
                  () => MediaActions.share(
                    context,
                    path: song.filePath ?? '',
                    name: '${song.title}.mp3',
                    mimeType: 'audio/mpeg',
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Detalhes'),
                subtitle: const Text('Álbum, artista, tamanho e caminho'),
                onTap: () =>
                    go(() => MediaDetailsSheet.showSong(context, song)),
              ),
              // Item 3.3 — tela própria do equalizador (o estado é global,
              // a entrada fica aqui por alcance: é onde o ouvinte está).
              ListTile(
                leading: const Icon(Icons.equalizer),
                title: const Text('Equalizador'),
                subtitle: const Text('Bandas, presets e reforço de graves'),
                onTap: () => go(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EqualizerScreen(),
                    ),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  isAsset ? Icons.lock_outline : Icons.delete_outline,
                  color: isAsset ? null : colors.error,
                ),
                title: Text(
                  isAsset ? 'Excluir do aparelho' : 'Excluir do aparelho',
                  style: isAsset ? null : TextStyle(color: colors.error),
                ),
                subtitle: isAsset
                    ? const Text(MusicScreen.assetLockedMessage)
                    : const Text('Some da lista, da fila e das playlists'),
                onTap: isAsset
                    ? () {
                        Navigator.pop(sheetContext);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text(MusicScreen.assetLockedMessage),
                          ),
                        );
                      }
                    : () => go(() => _deleteCurrent(context, provider, song)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Item 3.1 — seletor do timer de sono: 15/30/45/60, personalizado e
  /// "ao fim da faixa". O estado mora no AudioService (sobrevive a
  /// segundo plano); aqui só delega ao provider.
  Future<void> _showSleepMenu(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            if (provider.sleepTimerActive)
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(
                  provider.sleepMode == SleepTimerMode.trackEnd
                      ? 'Dormindo ao fim da faixa'
                      : 'Dormindo em '
                            '${formatDuration(provider.sleepRemaining)}',
                ),
                subtitle: const Text('O áudio dá fade e para sozinho.'),
              ),
            for (final int minutes in const <int>[15, 30, 45, 60])
              ListTile(
                leading: const Icon(Icons.timer),
                title: Text('$minutes minutos'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.startSleepTimer(Duration(minutes: minutes));
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Personalizado'),
              subtitle: const Text('De 1 a 720 minutos'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickCustomSleep(context, provider);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_outlined),
              title: const Text('Ao fim da faixa'),
              subtitle: const Text(
                'Para no fim desta faixa, sem pular para a próxima',
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                provider.startSleepAtTrackEnd();
              },
            ),
            if (provider.sleepTimerActive) ...<Widget>[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('Desligar timer'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.cancelSleepTimer();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Item 3.1 — duração personalizada do timer de sono (1–720 minutos).
  Future<void> _pickCustomSleep(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    final TextEditingController controller = TextEditingController();
    String? error;
    final int? minutes = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (
          BuildContext innerContext,
          void Function(void Function()) setState,
        ) =>
            AlertDialog(
          title: const Text('Timer personalizado'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Minutos',
              hintText: 'Ex.: 20',
              errorText: error,
            ),
            onSubmitted: (_) {
              final int? value = int.tryParse(controller.text.trim());
              if (value != null && value >= 1 && value <= 720) {
                Navigator.pop(dialogContext, value);
              } else {
                setState(() => error = 'Informe um número de 1 a 720.');
              }
            },
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final int? value = int.tryParse(controller.text.trim());
                if (value != null && value >= 1 && value <= 720) {
                  Navigator.pop(dialogContext, value);
                } else {
                  setState(() => error = 'Informe um número de 1 a 720.');
                }
              },
              child: const Text('Agendar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (minutes != null) {
      provider.startSleepTimer(Duration(minutes: minutes));
    }
  }

  /// Adiciona a faixa em reprodução a uma playlist escolhida.
  Future<void> _addCurrentToPlaylist(
    BuildContext context,
    PlaylistProvider playlists,
    Song song,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: playlists.playlists.length,
          itemBuilder: (BuildContext _, int index) {
            final playlist = playlists.playlists[index];
            return ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              subtitle: Text('${playlist.songCount} faixas'),
              onTap: () async {
                await playlists.addSong(playlist.id, song);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                messenger.showSnackBar(
                  SnackBar(content: Text('Adicionada a "${playlist.name}"')),
                );
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Song? song = provider.currentSong;

    final bool canControl = provider.hasCurrentSong;
    final bool sliderEnabled = canControl && provider.duration > Duration.zero;
    final double maxMs = provider.duration.inMilliseconds
        .clamp(1, 1 << 62)
        .toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agora tocando'),
        actions: [
          // Item 3.1: timer de sono — ícone aceso quando agendado; o
          // tempo restante aparece no chip acima do slider. Sem faixa
          // corrente não há o que dormir, então some junto com as ações.
          if (song != null)
            IconButton(
              tooltip: 'Timer de sono',
              icon: Icon(
                provider.sleepTimerActive
                    ? Icons.bedtime
                    : Icons.bedtime_outlined,
              ),
              color: provider.sleepTimerActive ? colors.primary : null,
              onPressed: () => _showSleepMenu(context, provider),
            ),
          // Item 3.2: velocidade — mesma grade e mesmo rótulo do player
          // de vídeo (video_player_screen): ícone de texto "1.5x".
          if (song != null)
            PopupMenuButton<double>(
              tooltip: 'Velocidade ${provider.playbackSpeed}x',
              icon: Text(
                '${provider.playbackSpeed}x',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: provider.playbackSpeed != 1.0
                      ? colors.primary
                      : null,
                ),
              ),
              onSelected: provider.setPlaybackSpeed,
              itemBuilder: (BuildContext menuContext) =>
                  SettingsProvider.playbackSpeedOptions
                      .map(
                        (double s) => PopupMenuItem<double>(
                          value: s,
                          child: Text('${s}x'),
                        ),
                      )
                      .toList(),
            ),
          if (song != null)
            // Menu de 3 pontinhos: as ações da faixa que TOCA ficam aqui, que
            // é onde o usuário já está. A lixeira isolada foi substituída por
            // este menu — mesmo padrão do visualizador de fotos.
            IconButton(
              tooltip: 'Ações da faixa',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showSongActions(context, provider, song),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ---- Capa grande (expande no espaço restante) ----
            Expanded(
              child: Center(
                child: song == null
                    ? Icon(
                        Icons.music_note,
                        size: 120,
                        color: colors.outlineVariant,
                      )
                    : AlbumArtwork(
                        song: song,
                        size: 320,
                        fallbackColor: colors.surfaceContainerHighest,
                      ),
              ),
            ),

            // ---- Título / artista ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Text(
                    song?.title ?? 'Nenhuma faixa selecionada',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song?.displayArtist ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ---- Slider de progresso (seek arrastável) ----
            // Item 2.1: slider e tempos reagem SÓ ao notifier de posição
            // (ValueListenableBuilder) — o resto desta tela reconstrói em
            // mudança de faixa/status/modo, não a cada tick de 200ms.
            ValueListenableBuilder<Duration>(
              valueListenable: provider.positionListenable,
              builder: (context, position, _) {
                final double sliderValue =
                    (_dragValueMs ?? position.inMilliseconds.toDouble()).clamp(
                      0,
                      maxMs,
                    );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Item 3.1: chip do timer de sono — vive dentro do
                    // builder de posição, então a contagem regressiva
                    // atualiza a cada tick enquanto toca (e a cada rebuild
                    // da tela, ex.: faixa pausada, ao iniciar/cancelar).
                    if (song != null && provider.sleepTimerActive)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Icon(
                              Icons.timer_outlined,
                              size: 16,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              provider.sleepMode == SleepTimerMode.trackEnd
                                  ? 'Dormir ao fim da faixa'
                                  : 'Dormir em '
                                        '${formatDuration(provider.sleepRemaining)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: colors.primary),
                            ),
                            IconButton(
                              tooltip: 'Desligar timer',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: provider.cancelSleepTimer,
                            ),
                          ],
                        ),
                      ),
                    Slider(
                      value: sliderValue,
                      max: maxMs,
                      onChanged: sliderEnabled
                          ? (double value) {
                              setState(() => _dragValueMs = value);
                            }
                          : null,
                      onChangeStart: sliderEnabled
                          ? (_) => setState(() => _dragValueMs = sliderValue)
                          : null,
                      onChangeEnd: sliderEnabled
                          ? (double value) {
                              provider.seek(
                                Duration(milliseconds: value.round()),
                              );
                              setState(() => _dragValueMs = null);
                            }
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatDuration(
                              Duration(milliseconds: sliderValue.round()),
                            ),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          Text(
                            formatDuration(provider.duration),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),

            // ---- Controles: shuffle / prev / play / next / repeat ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Embaralhar',
                    iconSize: 26,
                    color: provider.shuffle ? colors.primary : null,
                    icon: const Icon(Icons.shuffle),
                    onPressed: provider.toggleShuffle,
                  ),
                  IconButton(
                    tooltip: 'Anterior',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: canControl ? provider.previous : null,
                  ),
                  IconButton.filled(
                    tooltip: provider.isPlaying ? 'Pausar' : 'Tocar',
                    iconSize: 52,
                    icon: Icon(
                      provider.isPlaying
                          ? Icons.pause
                          : (provider.status == PlayerStatus.completed
                                ? Icons.replay
                                : Icons.play_arrow),
                    ),
                    onPressed: canControl ? provider.togglePlayPause : null,
                  ),
                  IconButton(
                    tooltip: 'Próxima',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_next),
                    onPressed: canControl ? provider.next : null,
                  ),
                  IconButton(
                    tooltip: 'Repetir',
                    iconSize: 26,
                    color: provider.repeat != RepeatMode.off
                        ? colors.primary
                        : null,
                    icon: Icon(
                      provider.repeat == RepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                    ),
                    onPressed: provider.cycleRepeat,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
