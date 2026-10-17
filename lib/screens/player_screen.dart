import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/media_ref.dart';
import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/settings_provider.dart';
import '../services/album_artwork_cache.dart';
import '../services/audio_service.dart';
import '../services/error_log_service.dart';
import '../utils/format.dart';
import '../widgets/album_artwork.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/playlist_picker_sheet.dart';
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
        SnackBar(content: Text(l10nOf(context).assetLockedMessage)),
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

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
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
                title: Text(l10n.addToPlaylist),
                onTap: () =>
                    go(() => _addCurrentToPlaylist(context, playlists, song)),
              ),
              // Item 4.1 — favoritar pelo menu (mesmo efeito do coração
              // das ações rápidas; estado lido na abertura, o menu fecha).
              Builder(
                builder: (BuildContext tileContext) {
                  final bool fav =
                      FavoritesProvider.instance.isFavorite(song.id);
                  return ListTile(
                    leading: Icon(
                      fav ? Icons.favorite : Icons.favorite_border,
                      color: fav ? colors.error : null,
                    ),
                    title: Text(fav ? l10n.unfavorite : l10n.favorite),
                    subtitle: fav
                        ? Text(l10n.favoriteOffSub)
                        : Text(l10n.favoriteOnSub),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      FavoritesProvider.instance.toggle(song);
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text(l10n.share),
                subtitle: Text(
                  isAsset ? l10n.shareAssetSub : l10n.shareApps,
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
                title: Text(l10n.details),
                subtitle: Text(l10n.detailsSub),
                onTap: () =>
                    go(() => MediaDetailsSheet.showSong(context, song)),
              ),
              // Item 3.3 — tela própria do equalizador (o estado é global,
              // a entrada fica aqui por alcance: é onde o ouvinte está).
              ListTile(
                leading: const Icon(Icons.equalizer),
                title: Text(l10n.equalizerTitle),
                subtitle: Text(l10n.equalizerSheetSubtitle),
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
                  l10n.deleteFromDevice,
                  style: isAsset ? null : TextStyle(color: colors.error),
                ),
                subtitle: isAsset
                    ? Text(l10n.assetLockedMessage)
                    : Text(l10n.deleteTrackGoneSub),
                onTap: isAsset
                    ? () {
                        Navigator.pop(sheetContext);
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l10n.assetLockedMessage),
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
    // Item 5.2 — duração padrão escolhida em Configurações (0 = off).
    final int defaultMinutes = provider.sleepDefaultMinutes;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              // Item 5.2 — atalho do padrão: agenda sem escolher.
              if (defaultMinutes > 0)
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(l10n.minutesCount(defaultMinutes)),
                  subtitle: Text(l10n.sleepDefaultLabel),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    provider.startSleepTimer(
                      Duration(minutes: defaultMinutes),
                    );
                  },
                ),
              if (provider.sleepTimerActive)
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(
                    provider.sleepMode == SleepTimerMode.trackEnd
                        ? l10n.sleepActiveUntilEnd
                        : l10n.sleepActiveIn(
                            formatDuration(provider.sleepRemaining),
                          ),
                  ),
                  subtitle: Text(l10n.sleepFadeNote),
                ),
              for (final int minutes in const <int>[15, 30, 45, 60])
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: Text(l10n.minutesCount(minutes)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    provider.startSleepTimer(Duration(minutes: minutes));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.customSleep),
                subtitle: Text(l10n.customSleepSub),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickCustomSleep(context, provider);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(l10n.atTrackEnd),
                subtitle: Text(l10n.atTrackEndSub),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.startSleepAtTrackEnd();
                },
              ),
              if (provider.sleepTimerActive) ...<Widget>[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_off_outlined),
                  title: Text(l10n.cancelTimer),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    provider.cancelSleepTimer();
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Item 3.1 — duração personalizada do timer de sono (1–720 minutos).
  Future<void> _pickCustomSleep(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    // Item 5.2: começa no valor padrão de Configurações (se houver).
    final int defaultMinutes = provider.sleepDefaultMinutes;
    final TextEditingController controller = TextEditingController(
      text: defaultMinutes > 0 ? '$defaultMinutes' : '',
    );
    String? error;
    final int? minutes = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (
          BuildContext innerContext,
          void Function(void Function()) setState,
        ) =>
            AlertDialog(
              title: Text(l10nOf(innerContext).customTimerTitle),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10nOf(innerContext).minutesLabel,
                  hintText: l10nOf(innerContext).minutesHint,
                  errorText: error,
                ),
                onSubmitted: (_) {
                  final int? value = int.tryParse(controller.text.trim());
                  if (value != null && value >= 1 && value <= 720) {
                    Navigator.pop(dialogContext, value);
                  } else {
                    setState(
                      () => error = l10nOf(innerContext).timerRangeError,
                    );
                  }
                },
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10nOf(innerContext).cancel),
                ),
                FilledButton(
                  onPressed: () {
                    final int? value = int.tryParse(controller.text.trim());
                    if (value != null && value >= 1 && value <= 720) {
                      Navigator.pop(dialogContext, value);
                    } else {
                      setState(
                        () => error = l10nOf(innerContext).timerRangeError,
                      );
                    }
                  },
                  child: Text(l10nOf(innerContext).schedule),
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
  /// Item 4.4 — escolhe a playlist no seletor (com "Nova playlist"
  /// embutida) e adiciona a faixa corrente.
  Future<void> _addCurrentToPlaylist(
    BuildContext context,
    PlaylistProvider playlists,
    Song song,
  ) async {
    await showPlaylistPickerSheet(
      context,
      onPick: (Playlist playlist) async {
        await playlists.addSong(playlist.id, song);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10nOf(context).addedToPlaylist(playlist.name)),
            ),
          );
        }
      },
      subtitleOf: (Playlist playlist) =>
          l10nOf(context).tracksCount(playlist.songCount),
    );
  }

  /// Item 3.5 — folha "Fila": a ordem que o player segue, com
  /// tocar-aqui, reordenar (arrastar pelo alça) e remover. O conteúdo
  /// assiste o provider (ChangeNotifierProvider.value) — remover ou
  /// reordenar refaz a lista sozinho, sem fechar a folha.
  Future<void> _showQueueSheet(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ChangeNotifierProvider<PlayerProvider>.value(
          value: provider,
          child: const _QueueSheet(),
        ),
      ),
    );
  }

  /// Item 3.6 — folha de letras OFFLINE sincronizada com a posição.
  Future<void> _showLyricsSheet(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    final Song? song = provider.currentSong;
    if (song == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Rota nova: o provider declarado no escopo desta tela não
      // alcança o sheet — reanexa a MESMA instância (folio da fila).
      builder: (BuildContext sheetContext) =>
          ChangeNotifierProvider<PlayerProvider>.value(
        value: provider,
        child: LyricsSheet(song: song),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Item 3.7 — cores derivadas da capa + blocos de layout
  // ------------------------------------------------------------------

  /// ColorScheme derivado da capa da faixa corrente (quando existe).
  ColorScheme? _capaScheme;

  /// MediaId a que [_capaScheme] pertence — só vale se for o mesmo da
  /// faixa corrente (guarda de uso em [_colorsFor]).
  int? _capaForMediaId;

  /// Última requisição em voo — evita corrida quando o usuário troca de
  /// faixa rápido (o resultado antigo é descartado no retorno).
  int? _capaRequest;

  /// Item 3.7 — tema da tela: o da casa, a menos que a capa corrente
  /// tenha gerado um ColorScheme ([ColorScheme.fromImageProvider]).
  ColorScheme _colorsFor(ColorScheme base, Song? song) {
    final int? mediaId = song?.mediaId;
    final bool match = mediaId != null &&
        mediaId == _capaForMediaId &&
        _capaScheme != null;
    return match ? _capaScheme! : base;
  }

  /// Dispara a derivação da capa uma vez por mediaId (guardado — não é
  /// setState; o resultado chega assíncrono em [_deriveCapaScheme]).
  void _requestCapaScheme(Song? song, Brightness brightness) {
    final int? mediaId = song?.mediaId;
    if (mediaId == null) return;
    if (mediaId == _capaForMediaId || mediaId == _capaRequest) return;
    _capaRequest = mediaId;
    _deriveCapaScheme(mediaId, brightness);
  }

  Future<void> _deriveCapaScheme(int mediaId, Brightness brightness) async {
    try {
      final Uint8List? bytes = await AlbumArtworkCache.instance.load(mediaId);
      if (!mounted || _capaRequest != mediaId) return;
      ColorScheme? derived;
      if (bytes != null && bytes.isNotEmpty) {
        derived = await ColorScheme.fromImageProvider(
          provider: MemoryImage(bytes),
          brightness: brightness,
        );
      }
      if (!mounted || _capaRequest != mediaId) return;
      setState(() {
        _capaForMediaId = mediaId;
        _capaScheme = derived;
        _capaRequest = null;
      });
    } catch (e, s) {
      if (!mounted || _capaRequest != mediaId) return;
      // Sem cor derivada: a tela segue com o tema da casa — a falha de
      // extração de cor nunca derruba o player.
      setState(() {
        _capaForMediaId = mediaId;
        _capaScheme = null;
        _capaRequest = null;
      });
      ErrorLogService.logSync('player/capaColors', e, s);
    }
  }

  /// Item 3.7 — capa com lado `min(320, espaço)`: em bloco menor que
  /// 320 (tela baixa, coluna de paisagem) ela ENCOLHE em vez de ser
  /// esmagada — o código antigo forçava 320 fixo e o Container virava
  /// 320×altura do bloco (capa deformada).
  Widget _artwork(
    BoxConstraints constraints, {
    required Song? song,
    required ColorScheme colors,
  }) {
    final double side = math.min(
      320.0,
      math.min(constraints.maxWidth, constraints.maxHeight),
    );
    if (song == null) {
      return Icon(
        Icons.music_note,
        size: math.min(120.0, side),
        color: colors.outlineVariant,
      );
    }
    return AlbumArtwork(
      song: song,
      size: side,
      fallbackColor: colors.surfaceContainerHighest,
    );
  }

  Widget _titleBlock(
    BuildContext context,
    Song? song,
    ColorScheme colors,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            song?.title ?? l10nOf(context).noTrackSelected,
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
    );
  }

  /// Slider de progresso (seek arrastável) + chip do timer de sono.
  ///
  /// Item 2.1: slider e tempos reagem SÓ ao notifier de posição
  /// (ValueListenableBuilder) — o resto desta tela reconstrói em
  /// mudança de faixa/status/modo, não a cada tick de 200ms.
  Widget _seekBlock(
    BuildContext context,
    PlayerProvider provider,
    Song? song,
    ColorScheme colors,
    bool sliderEnabled,
    double maxMs,
  ) {
    return ValueListenableBuilder<Duration>(
      valueListenable: provider.positionListenable,
      builder: (context, position, _) {
        final AppLocalizations l10n = l10nOf(context);
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
                          ? l10n.sleepChipUntilEnd
                          : l10n.sleepChipIn(
                              formatDuration(provider.sleepRemaining),
                            ),
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: colors.primary),
                    ),
                    IconButton(
                      tooltip: l10n.cancelTimer,
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: provider.cancelSleepTimer,
                    ),
                  ],
                ),
              ),
            // Item 5.3 — rótulo para leitor de tela: o Slider sozinho
            // só anuncia o valor numérico ("X de 1000"), sem dizer o
            // que é.
            Semantics(
              label: l10n.seekLabel,
              child: Slider(
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
    );
  }

  /// Controles: shuffle / anterior / play / próxima / repetir.
  Widget _transportRow(
    AppLocalizations l10n,
    PlayerProvider provider,
    ColorScheme colors,
    bool canControl,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: l10n.shuffleTooltip,
            iconSize: 26,
            color: provider.shuffle ? colors.primary : null,
            icon: const Icon(Icons.shuffle),
            onPressed: provider.toggleShuffle,
          ),
          IconButton(
            tooltip: l10n.previous,
            iconSize: 40,
            icon: const Icon(Icons.skip_previous),
            onPressed: canControl ? provider.previous : null,
          ),
          IconButton.filled(
            tooltip: provider.isPlaying ? l10n.pause : l10n.play,
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
            tooltip: l10n.next,
            iconSize: 40,
            icon: const Icon(Icons.skip_next),
            onPressed: canControl ? provider.next : null,
          ),
          IconButton(
            tooltip: l10n.repeat,
            iconSize: 26,
            color: provider.repeat != RepeatMode.off ? colors.primary : null,
            icon: Icon(
              provider.repeat == RepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
            ),
            onPressed: provider.cycleRepeat,
          ),
        ],
      ),
    );
  }

  /// Item 3.7 — fila, timer e velocidade como botões VISÍVEIS na tela
  /// (antes só no AppBar, que ficava com cinco ações) + o coração do
  /// favorito (item 4.1 — o 3.7 deixou a vaga, o 4.1 preencheu).
  Widget _quickActions(
    BuildContext context,
    AppLocalizations l10n,
    PlayerProvider provider,
    ColorScheme colors,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: l10n.queueTooltip,
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueueSheet(context, provider),
          ),
          IconButton(
            tooltip: l10n.sleepTimerTooltip,
            icon: Icon(
              provider.sleepTimerActive
                  ? Icons.bedtime
                  : Icons.bedtime_outlined,
            ),
            color: provider.sleepTimerActive ? colors.primary : null,
            onPressed: () => _showSleepMenu(context, provider),
          ),
          PopupMenuButton<double>(
            tooltip: l10n.speedTooltip('${provider.playbackSpeed}'),
            icon: Text(
              '${provider.playbackSpeed}x',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color:
                    provider.playbackSpeed != 1.0 ? colors.primary : null,
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
          // Item 4.1 — coração do favorito da faixa corrente (estado do
          // singleton; só este botão reconstrói quando o estado muda).
          ListenableBuilder(
            listenable: FavoritesProvider.instance,
            builder: (BuildContext context, _) {
              final Song? current = provider.currentSong;
              final bool fav = current != null &&
                  FavoritesProvider.instance.isFavorite(current.id);
              return IconButton(
                tooltip: fav ? l10n.unfavorite : l10n.favorite,
                icon: Icon(
                  fav ? Icons.favorite : Icons.favorite_border,
                  color: fav ? colors.error : colors.onSurfaceVariant,
                ),
                onPressed: current == null
                    ? null
                    : () => FavoritesProvider.instance.toggle(current),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = l10nOf(context);
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme themeColors = Theme.of(context).colorScheme;
    final Song? song = provider.currentSong;

    final bool canControl = provider.hasCurrentSong;
    final bool sliderEnabled = canControl && provider.duration > Duration.zero;
    final double maxMs = provider.duration.inMilliseconds
        .clamp(1, 1 << 62)
        .toDouble();

    // Item 3.7: cores derivadas da capa (assíncrono, guardado) e
    // requisição de nova derivação quando a faixa — e a capa — mudam.
    final ColorScheme colors = _colorsFor(themeColors, song);
    _requestCapaScheme(song, themeColors.brightness);

    return Theme(
      data: Theme.of(context).copyWith(colorScheme: colors),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.nowPlaying),
          actions: [
            // Item 3.6: letras offline (.lrc ao lado do áudio ou ID3
            // USLT do MP3) — folha com destaque da linha sincronizado.
            if (song != null)
              IconButton(
                tooltip: l10n.lyricsTooltip,
                icon: const Icon(Icons.lyrics),
                onPressed: () => _showLyricsSheet(context, provider),
              ),
            // Item 3.7: fila (3.5), timer (3.1) e velocidade (3.2)
            // saíram daqui — viraram botões visíveis na tela
            // (_quickActions); o AppBar fica com o que é pontual
            // (letras + ações da faixa).
            if (song != null)
              // Menu de 3 pontinhos: as ações da faixa que TOCA ficam aqui, que
              // é onde o usuário já está. A lixeira isolada foi substituída por
              // este menu — mesmo padrão do visualizador de fotos.
              IconButton(
                tooltip: l10n.trackActionsTooltip,
                icon: const Icon(Icons.more_vert),
                onPressed: () => _showSongActions(context, provider, song),
              ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool landscape =
                  constraints.maxWidth > constraints.maxHeight;

              // Item 3.7 — duas colunas em paisagem: capa à esquerda
              // (lado min(320, espaço)), conteúdo à direita rolando se
              // não couber — a altura de paisagem é curta.
              if (landscape) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: LayoutBuilder(
                        builder: (BuildContext _, BoxConstraints c) => Center(
                          child: _artwork(c, song: song, colors: colors),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _titleBlock(context, song, colors),
                              const SizedBox(height: 8),
                              _seekBlock(
                                context,
                                provider,
                                song,
                                colors,
                                sliderEnabled,
                                maxMs,
                              ),
                              const SizedBox(height: 4),
                              _transportRow(l10n, provider, colors, canControl),
                              if (song != null)
                                _quickActions(context, l10n, provider, colors),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }

              // Retrato: capa em cima (expande até 320 e ENCOLHE se o
              // bloco for menor — o antigo 320 fixo esmagava em tela
              // baixa), título/seek/controles/ações embaixo.
              return Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (BuildContext _, BoxConstraints c) => Center(
                        child: _artwork(c, song: song, colors: colors),
                      ),
                    ),
                  ),
                  _titleBlock(context, song, colors),
                  const SizedBox(height: 16),
                  _seekBlock(
                    context,
                    provider,
                    song,
                    colors,
                    sliderEnabled,
                    maxMs,
                  ),
                  const SizedBox(height: 8),
                  _transportRow(l10n, provider, colors, canControl),
                  if (song != null) _quickActions(context, l10n, provider, colors),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Item 3.5 — conteúdo da folha "Fila" (lista viva do provider).
class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<Song> queue = provider.queue;
    final AppLocalizations l10n = l10nOf(context);

    if (queue.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.queueEmpty,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            l10n.queueHeader(queue.length),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
        // Flexible (não altura fixa): o sheet limita o conteúdo ao que
        // sobra do viewport — a folha ocupa o máximo disponível e a
        // lista rola dentro, sem estourar o RenderFlex.
        Flexible(
          child: ReorderableListView.builder(
            // O drag só começa pelo alça: o restante do item é para
            // TOCAR (sem arraste acidental ao interagir com o tile).
            buildDefaultDragHandles: false,
            itemCount: queue.length,
            // onReorderItem (não o onReorder legado) já entrega o
            // destino AJUSTADO pós-remoção — a posição FINAL que o
            // PlaybackQueue.move espera.
            onReorderItem: provider.queueMove,
            itemBuilder: (BuildContext context, int index) {
              final Song song = queue[index];
              final bool isCurrent = provider.currentSong?.id == song.id;
              return ListTile(
                key: ValueKey<String>(song.id),
                leading: isCurrent
                    ? Icon(Icons.graphic_eq, color: colors.primary)
                    : Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                      ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  isCurrent ? l10n.playingNow : song.displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: l10n.removeFromQueue,
                      icon: const Icon(Icons.close),
                      onPressed: () => provider.queueRemoveAt(index),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  provider.playQueue(queue, index);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
