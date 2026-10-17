// Item 6.2 — teste direto do PermissionBanner extraído de music_screen.dart.
//
// A caracterização prévia (indireta) não existe: em host a permissão de áudio
// volta concedida (Platform.isAndroid é falso) e o banner nunca aparece na
// tela. Aqui os dois ramos são renderizados direto no widget, com o estado do
// provider forçado por override do getter.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/widgets/permission_banner.dart';

import 'support/playable_audio_service.dart';

class _EmptySongRepository extends SongRepository {
  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => const [];
}

class _NullSessionRepository extends SessionRepository {
  @override
  Future<void> save(Song song, Duration position) async {}

  @override
  Future<void> saveQueue(List<String> ids, int index) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<(Song?, Duration)> load() async => (null, Duration.zero);

  @override
  Future<(List<String>, int)> loadQueue() async => (const <String>[], -1);
}

PlayerProvider _provider() => PlayerProvider(
  PlayableAudioService(),
  songRepository: _EmptySongRepository(),
  sessionRepository: _NullSessionRepository(),
);

/// Ramo "bloqueada": o banner só muda de texto/botão quando o estado é
/// permanentlyDenied, que o provider real só alcança via plugin nativo.
class _BlockedPlayerProvider extends PlayerProvider {
  _BlockedPlayerProvider()
    : super(
        PlayableAudioService(),
        songRepository: _EmptySongRepository(),
        sessionRepository: _NullSessionRepository(),
      );

  @override
  AudioPermissionState get permission => AudioPermissionState.permanentlyDenied;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ramo padrão: pede acesso com botão Permitir', (
    WidgetTester t,
  ) async {
    final PlayerProvider provider = _provider();
    addTearDown(provider.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PermissionBanner(provider: provider)),
      ),
    );

    expect(
      find.text('Permita o acesso às músicas para ver sua biblioteca.'),
      findsOneWidget,
    );
    expect(find.text('Permitir'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('ramo bloqueado: muda o texto e aponta para os ajustes', (
    WidgetTester t,
  ) async {
    final _BlockedPlayerProvider provider = _BlockedPlayerProvider();
    addTearDown(provider.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PermissionBanner(provider: provider)),
      ),
    );

    expect(
      find.text(
        'Permissão bloqueada. Libere nas Configurações do sistema para ver '
        'suas músicas.',
      ),
      findsOneWidget,
    );
    expect(find.text('Abrir ajustes'), findsOneWidget);
    expect(find.text('Permitir'), findsNothing);
  });
}
