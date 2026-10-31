import 'package:flutter/foundation.dart';

import '../services/error_log_service.dart';
import '../services/playlist_database.dart';

/// Item 4.2 — uma linha do histórico (tabela `song_stats`).
class SongStat {
  const SongStat({
    required this.songId,
    required this.playCount,
    required this.lastPlayedMs,
  });

  final String songId;
  final int playCount;
  final int lastPlayedMs;
}

/// Item 4.2 — histórico de reprodução e "mais tocadas" (tabela
/// `song_stats`).
///
/// Singleton notificável, mesmo motivo do [FavoritesProvider]: as
/// playlists automáticas "Tocadas recentemente" e "Mais tocadas"
/// aparecem na aba Playlists e no detalhe empurrado — rotas diferentes
/// que precisam reagir quando um play entra ou quando o histórico é
/// limpo, sem encadear providers em toda árvore.
class HistoryProvider extends ChangeNotifier {
  HistoryProvider._();

  /// Estado único, vivo junto com o app (nunca é disposed).
  static final HistoryProvider instance = HistoryProvider._();

  List<SongStat> _stats = const [];
  bool _loaded = false;
  bool _isDisposed = false;

  /// Stats completos, na ordem "mais tocadas" (do banco: contagem
  /// desc, empate: último toque desc).
  List<SongStat> get stats => List<SongStat>.unmodifiable(_stats);

  int get count => _stats.length;
  bool get loaded => _loaded;

  /// Ids em ordem "tocado recentemente" (último toque primeiro).
  List<String> get recentIds {
    final List<SongStat> byRecent = [..._stats]
      ..sort(
        (SongStat a, SongStat b) => b.lastPlayedMs.compareTo(a.lastPlayedMs),
      );
    return [for (final SongStat s in byRecent) s.songId];
  }

  /// Ids em ordem "mais tocadas" (já vem assim do banco).
  List<String> get mostPlayedIds => [for (final SongStat s in _stats) s.songId];

  /// Carrega do banco (idempotente — a partir do segundo chamado vira
  /// refresh). Falha vira histórico vazio + log: nunca derruba o app.
  Future<void> load() async {
    if (_loaded) return;
    await refresh();
  }

  /// Relê o banco e republica (pós-gravação de play e resync após
  /// falha). Mesma tolerância de [load].
  Future<void> refresh() async {
    if (_isDisposed) return;
    try {
      final List<Map<String, Object?>> rows = await PlaylistDatabase.getStats();
      _stats = <SongStat>[
        for (final Map<String, Object?> row in rows)
          SongStat(
            songId: row['song_id'] as String,
            playCount: ((row['play_count'] as num?) ?? 0).toInt(),
            lastPlayedMs: ((row['last_played'] as num?) ?? 0).toInt(),
          ),
      ];
      _loaded = true;
    } catch (e, s) {
      _stats = const [];
      _loaded = true;
      ErrorLogService.logSync('history/refresh', e, s);
    }
    _notify();
  }

  /// Limpa todo o histórico: estado zera na hora (otimista) e o banco
  /// em seguida; erro de escrita vira log + resync de verdade.
  Future<void> clear() async {
    if (_isDisposed) return;
    _stats = const [];
    _loaded = true;
    _notify();
    try {
      await PlaylistDatabase.clearHistory();
    } catch (e, s) {
      ErrorLogService.logSync('history/clear', e, s);
      await refresh();
    }
  }

  void _notify() {
    if (_isDisposed) return;
    notifyListeners();
  }

  /// Zera o estado em memória (testes — cada teste cuida do próprio
  /// banco, e o singleton compartilharia as stats entre testes).
  @visibleForTesting
  void resetForTest() {
    _stats = const [];
    _loaded = false;
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
