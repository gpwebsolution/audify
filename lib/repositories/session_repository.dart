import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song_model.dart';

/// Persistência da "última sessão" de reprodução.
///
/// Responsabilidade: guardar a faixa + posição + fila ativa da última
/// reprodução em shared_preferences para "continuar de onde parou".
/// Nenhuma lógica de negócio aqui — apenas serialização tolerante a falhas.
class SessionRepository {
  static const String _lastSongKey = 'last_song';
  static const String _lastPositionKey = 'last_position_ms';
  static const String _queueIdsKey = 'queue_ids';
  static const String _queueIndexKey = 'queue_index';

  /// Teto de ids persistidos por sessão. Filas gigantes ("tocar tudo" com
  /// milhares de faixas) não precisam ser todas gravadas: guardamos uma
  /// janela centrada na faixa corrente — o que importa para retomar é o
  /// entorno do que estava tocando.
  static const int maxQueueIds = 500;

  /// Salva a faixa e posição atuais.
  Future<void> save(Song song, Duration position) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSongKey, jsonEncode(song.toStored()));
      await prefs.setInt(_lastPositionKey, position.inMilliseconds);
    } catch (e) {
      // Falha de escrita não interrompe a reprodução.
      debugPrint('[SessionRepository] save falhou: $e');
    }
  }

  /// Salva a FILA ativa (ids na ordem em que estão, + índice corrente).
  ///
  /// Lista vazia apaga a fila salva (nada a retomar). Filas maiores que
  /// [maxQueueIds] são reduzidas a uma janela centrada em [index] — o
  /// índice devolvido nas leituras seguintes é reajustado para a janela.
  Future<void> saveQueue(List<String> ids, int index) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (ids.isEmpty) {
        await prefs.remove(_queueIdsKey);
        await prefs.remove(_queueIndexKey);
        return;
      }
      final int clamped = index.clamp(0, ids.length - 1);
      int start = 0;
      if (ids.length > maxQueueIds) {
        start = (clamped - maxQueueIds ~/ 2).clamp(0, ids.length - maxQueueIds);
      }
      final List<String> window = ids.sublist(
        start,
        min(start + maxQueueIds, ids.length),
      );
      await prefs.setString(_queueIdsKey, jsonEncode(window));
      await prefs.setInt(_queueIndexKey, clamped - start);
    } catch (e) {
      debugPrint('[SessionRepository] saveQueue falhou: $e');
    }
  }

  /// Apaga a sessão salva (faixa, posição E fila).
  ///
  /// Usado quando a faixa salva é excluída do aparelho: retomar a sessão
  /// apontaria para um arquivo inexistente.
  Future<void> clear() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastSongKey);
      await prefs.remove(_lastPositionKey);
      await prefs.remove(_queueIdsKey);
      await prefs.remove(_queueIndexKey);
    } catch (e) {
      debugPrint('[SessionRepository] clear falhou: $e');
    }
  }

  /// Retorna a fila salva: ids (na ordem da fila) e índice corrente.
  ///
  /// Sem fila salva (sessão antiga) devolve `(const [], -1)`. Dados
  /// corrompidos/ilegíveis caem no mesmo caminho — nunca lançam.
  Future<(List<String>, int)> loadQueue() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? json = prefs.getString(_queueIdsKey);
      if (json == null) return (const <String>[], -1);
      final List<String> ids = (jsonDecode(json) as List)
          .map((Object? e) => e?.toString() ?? '')
          .where((String id) => id.isNotEmpty)
          .toList();
      if (ids.isEmpty) return (const <String>[], -1);
      final int index = prefs.getInt(_queueIndexKey) ?? -1;
      return (ids, index < 0 || index >= ids.length ? -1 : index);
    } catch (e) {
      debugPrint('[SessionRepository] loadQueue falhou: $e');
      return (const <String>[], -1);
    }
  }

  /// Retorna a última faixa salva (ou null) e sua posição.
  ///
  /// Dados corrompidos/ilegíveis retornam (null, zero) — nunca lançam.
  Future<(Song?, Duration)> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? json = prefs.getString(_lastSongKey);
      if (json == null) return (null, Duration.zero);

      final Map<String, Object?> stored = (jsonDecode(json) as Map)
          .cast<String, Object?>();
      final Song? song = Song.fromStored(stored);
      if (song == null || song.id.isEmpty) return (null, Duration.zero);
      final int positionMs = prefs.getInt(_lastPositionKey) ?? 0;
      return (song, Duration(milliseconds: positionMs));
    } catch (e) {
      // Sessão corrompida/ilegível: ignora, mas registra o porquê.
      debugPrint('[SessionRepository] load falhou: $e');
      return (null, Duration.zero);
    }
  }
}
