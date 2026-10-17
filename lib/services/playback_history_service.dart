import 'dart:async';

import '../models/song_model.dart';
import 'error_log_service.dart';
import 'playlist_database.dart';

/// Item 4.2 — regra de contagem do histórico de reprodução.
///
/// Conta UMA reprodução quando a posição passa de 30 s OU de 50% da
/// duração da faixa (o que vier primeiro), e nunca a cada seek ou
/// retorno: o flag fica por EXECUÇÃO da faixa e só reseta quando a
/// faixa corrente muda (troca, fim/replay ou parada).
///
/// Avaliação acontece nos ticks de posição enquanto o player está
/// tocando — um seek feito com a música pausada não conta (aproximação
/// honesta de "30 s ouvidos"; ver PENDENTE.md).
///
/// Injeções de teste: [onRecord] (persistência — nos testes um spy),
/// [clock] (relógio do `last_played`) e [onRecorded] (callback pós-
/// gravação, usado para refrescar a UI).
class PlaybackHistoryService {
  PlaybackHistoryService({
    Future<void> Function(String songId, int playedAtMs)? onRecord,
    Future<void> Function()? onRecorded,
    DateTime Function()? clock,
  }) : _onRecord = onRecord ?? _recordToDb,
       _clock = clock ?? DateTime.now {
    _onRecorded = onRecorded;
  }

  /// Metade da faixa vale como limiar mínimo (50%).
  static const Duration minListen = Duration(seconds: 30);

  /// Padrão de persistência: encaminha para a tabela `song_stats`.
  static Future<void> _recordToDb(String songId, int playedAtMs) =>
      PlaylistDatabase.recordPlay(songId, playedAtMs: playedAtMs);

  final Future<void> Function(String songId, int playedAtMs) _onRecord;
  late final Future<void> Function()? _onRecorded;
  final DateTime Function() _clock;

  /// Id da faixa em execução (mudança de faixa reseta o flag).
  String? _currentId;

  /// Execução já contada (null = ainda não contou nesta execução).
  String? _countedId;

  /// Tick de posição do player.
  ///
  /// A troca de faixa é detectada pelo próprio id — assim nenhum ponto
  /// que atribui `_currentSong` precisa chamar o serviço à mão.
  void onProgress(
    Song? song,
    Duration position,
    Duration totalDuration, {
    required bool isPlaying,
  }) {
    if (song == null) {
      _currentId = null;
      _countedId = null;
      return;
    }
    if (song.id != _currentId) {
      // Nova execução (inclusive voltar para uma faixa tocada antes):
      // zera o flag para poder contar de novo.
      _currentId = song.id;
      _countedId = null;
    }
    if (!isPlaying || _countedId != null) return;

    final bool halfReached =
        totalDuration > Duration.zero && position >= totalDuration ~/ 2;
    if (position < minListen && !halfReached) return;

    _countedId = song.id;
    final int playedAtMs = _clock().millisecondsSinceEpoch;
    unawaited(_safeRecord(song.id, playedAtMs));
  }

  /// Gravação é fire-and-forget: falha de banco nunca derruba o tick
  /// de posição do player.
  Future<void> _safeRecord(String songId, int playedAtMs) async {
    try {
      await _onRecord(songId, playedAtMs);
      await _onRecorded?.call();
    } catch (e, s) {
      ErrorLogService.logSync('history/record', e, s);
    }
  }
}
