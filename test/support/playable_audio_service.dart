// AudioService "tocável" para testes de fila/playlist.
//
// Por quê: em ambiente de teste o audioplayers não tem canal nativo e
// playSong FALHA de verdade (asset do teste inexistente / canal morto).
// Com o item 1.7, falha de arquivo dispara skip automático para a
// próxima faixa — o que mudaria currentSong no MEIO dos testes de
// fila/busca (cujo foco é a ordem da fila, não a recuperação de erro).
//
// Aqui playSong "dá certo" (status playing, sem erro): o provider
// enxerga o mesmo estado de um app normal tocando, e a recuperação de
// falha é testada à parte em playback_failure_skip_test.dart.

import 'package:audify/models/song_model.dart';
import 'package:audify/services/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mocka os canais do audioplayers para o VM não lançar
/// MissingPluginException na criação do AudioPlayer (o construtor real
/// chama `init` no canal nativo). Chamar em setUpAll dos testes que
/// instanciam AudioService/PlayableAudioService.
void mockAudioplayersChannels() {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (call) async => null,
  );
}

class PlayableAudioService extends AudioService {
  /// Faixas que "tocaram" até agora (útil para asserções).
  final List<Song> played = <Song>[];

  @override
  Future<void> playSong(Song song) async {
    played.add(song);
    _current = song;
    errorMessage.value = null;
    status.value = PlayerStatus.playing;
    duration.value = song.duration ?? Duration.zero;
    position.value = Duration.zero;
  }

  Song? _current;

  Song? get currentFake => _current;

  @override
  Future<void> pause() async {
    status.value = PlayerStatus.paused;
  }

  @override
  Future<void> resume() async {
    status.value = PlayerStatus.playing;
  }

  @override
  Future<void> stop() async {
    status.value = PlayerStatus.idle;
  }
}
