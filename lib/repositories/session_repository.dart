import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song_model.dart';

/// Persistência da "última sessão" de reprodução.
///
/// Responsabilidade: guardar a faixa + posição da última reprodução em
/// shared_preferences para "continuar de onde parou". Nenhuma lógica de
/// negócio aqui — apenas serialização/deserialização tolerante a falhas.
class SessionRepository {
  static const String _lastSongKey = 'last_song';
  static const String _lastPositionKey = 'last_position_ms';

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

  /// Retorna a última faixa salva (ou null) e sua posição.
  ///
  /// Dados corrompidos/ilegíveis retornam (null, zero) — nunca lançam.
  Future<(Song?, Duration)> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? json = prefs.getString(_lastSongKey);
      if (json == null) return (null, Duration.zero);

      final Map<String, Object?> stored =
          (jsonDecode(json) as Map).cast<String, Object?>();
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