import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Favoritos de PDFs persistidos em SharedPreferences (lista de caminhos).
/// Simples e suficiente para uso pessoal — sem banco.
class PdfFavoritesService extends ChangeNotifier {
  static const String _key = 'audify.pdf_favorites';

  Set<String> _favorites = {};
  bool _loaded = false;
  bool _isDisposed = false;

  Set<String> get favorites => _favorites;
  bool isFavorite(String path) => _favorites.contains(path);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<dynamic> raw =
          jsonDecode(prefs.getString(_key) ?? '[]') as List<dynamic>;
      _favorites = raw.whereType<String>().toSet();
    } catch (e) {
      debugPrint('[PdfFavorites] Falha ao carregar favoritos: $e');
      _favorites = {};
    }
    _loaded = true;
    _notify();
  }

  Future<void> toggle(String path) async {
    if (!_favorites.add(path)) _favorites.remove(path);
    _notify();
    await _persist();
  }

  Future<void> remove(String path) async {
    if (_favorites.remove(path)) {
      _notify();
      await _persist();
    }
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_favorites.toList()));
    } catch (e) {
      debugPrint('[PdfFavorites] Falha ao salvar favoritos: $e');
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
