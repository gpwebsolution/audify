import 'dart:typed_data';

import 'package:on_audio_query/on_audio_query.dart';

/// Cache das capas de álbum vindas do MediaStore.
///
/// Existe porque `OnAudioQuery.queryArtwork` NÃO tem cache nenhum: cada
/// chamada cria um `OnAudioQuery`, atravessa o MethodChannel e o lado nativo
/// decodifica a arte em disco (`ContentResolver.loadThumbnail`).
///
/// O custo real apareceu aqui: o player emite `notifyListeners()` a cada frame
/// (~60/s) durante a reprodução, e toda a lista de músicas reconstrói junto. Sem
/// cache, cada tile visível refazia a consulta nativa 60 vezes por segundo —
/// centenas de leituras de JPEG por segundo, com jank e consumo de bateria.
///
/// Duas camadas:
///  - [pending]: agrupa consultas em andamento pelo mesmo id, para N rebuilds
///    simultâneos compartilharem UMA ida ao nativo;
///  - [_bytes]: guarda o resultado para os próximos rebuilds.
class AlbumArtworkCache {
  AlbumArtworkCache._();

  static final AlbumArtworkCache instance = AlbumArtworkCache._();

  /// Reutilizada em vez de `new OnAudioQuery()` por chamada: o plugin é
  /// stateful e o canal MethodChannel não gosta de instâncias descartáveis.
  final OnAudioQuery _query = OnAudioQuery();

  final Map<int, Uint8List?> _bytes = <int, Uint8List?>{};
  final Map<int, Future<Uint8List?>> _pending = <int, Future<Uint8List?>>{};

  /// Limite de entradas em memória. Uma capa tem alguns KB; 500 capas
  /// cobrem qualquer sessão de uso normal com folga e impedem crescimento
  /// ilimitado numa biblioteca com milhares de faixas.
  static const int _maxEntries = 500;

  /// Devolve a capa de [mediaId], do cache quando possível.
  ///
  /// Never throws: falha de leitura devolve null e o chamador mostra o ícone
  /// de fallback — uma capa quebrada não pode derrubar a lista.
  Future<Uint8List?> load(int mediaId) {
    final Uint8List? cached = _bytes[mediaId];
    if (_bytes.containsKey(mediaId)) {
      // Busca em cache é o caminho comum durante a reprodução.
      return Future<Uint8List?>.value(cached);
    }

    // Já tem uma consulta em voo para este id: compartilha.
    final Future<Uint8List?>? inflight = _pending[mediaId];
    if (inflight != null) return inflight;

    final Future<Uint8List?> future = _query
        .queryArtwork(mediaId, ArtworkType.AUDIO)
        .then((Uint8List? data) {
          _remember(mediaId, data);
          return data;
        })
        .catchError((Object _) {
          // Sem capa é o caso comum (faixa sem arte embutida), não exceção.
          _remember(mediaId, null);
          return null;
        })
        .whenComplete(() => _pending.remove(mediaId));

    _pending[mediaId] = future;
    return future;
  }

  /// Descarta a capa de uma faixa (usado quando a faixa é excluída).
  void invalidate(int mediaId) {
    _bytes.remove(mediaId);
    _pending.remove(mediaId);
  }

  void clear() {
    _bytes.clear();
    _pending.clear();
  }

  void _remember(int mediaId, Uint8List? data) {
    if (_bytes.length >= _maxEntries) {
      // Remove a entrada mais antiga (o Map preserva a ordem de inserção).
      _bytes.remove(_bytes.keys.first);
    }
    _bytes[mediaId] = data;
  }
}

/// Carregador de capa usado por um widget, com o Future guardado.
///
/// O [FutureBuilder] exige o MESMO Future entre rebuilds: se o `future:` for
/// criado no `build`, o snapshot anterior é descartado e a arte pisca — e a
/// consulta nativa é refeita. Esta classe resolve os dois problemas mantendo o
/// cache global (compartilhado entre tiles) separado do Future local (por
/// widget).
class AlbumArtworkLoader {
  Future<Uint8List?>? _future;

  /// Future estável da capa. Usa o cache global por baixo.
  Future<Uint8List?> load(int mediaId) =>
      _future ??= AlbumArtworkCache.instance.load(mediaId);

  /// Descarta o Future local (o global continua válido).
  void reset() => _future = null;
}
