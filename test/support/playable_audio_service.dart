// AudioService "tocável" para testes de fila/playlist.
//
// Por quê: em ambiente de teste o motor de áudio (just_audio) não tem
// canal nativo e playSong FALHA de verdade (asset do teste inexistente /
// canal morto). Com o item 1.7, falha de arquivo dispara skip automático
// para a próxima faixa — o que mudaria currentSong no MEIO dos testes de
// fila/busca (cujo foco é a ordem da fila, não a recuperação de erro).
//
// Aqui playSong "dá certo" (status playing, sem erro): o provider
// enxerga o mesmo estado de um app normal tocando, e a recuperação de
// falha é testada à parte em playback_failure_skip_test.dart.
//
// Não há mocks de canal de plataforma (item 3.0): o AudioPlayer do
// just_audio constrói com plataforma IDLE quando o app nunca chama
// play()/setAudioSource — e nenhum teste real toca esses métodos (os
// testes de unidade publicam broadcast/posição diretamente).

import 'package:audify/models/song_model.dart';
import 'package:audify/services/audio_service.dart';

class PlayableAudioService extends AudioService {
  /// Faixas que "tocaram" até agora (útil para asserções).
  final List<Song> played = <Song>[];

  /// Item 3.2: espelha [setPlaybackSpeed] sem tocar o just_audio.
  ///
  /// Sob FakeAsync (testWidgets) o AudioPlayer real nunca completa
  /// setSpeed/setVolume (o futuro do just_audio não resolve nessa zona —
  /// em test() puro resolve; ver testes do serviço em
  /// playback_speed_test.dart). Aqui o duplo aplica o MESMO clamp e o
  /// mesmo broadcast do serviço real, para a UI/provider verem o estado.
  double _speed = 1.0;

  @override
  double get playbackSpeed => _speed;

  @override
  Future<void> setPlaybackSpeed(double value) async {
    _speed = value.clamp(0.5, 2.0).toDouble();
    broadcastPlaybackState();
  }

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
