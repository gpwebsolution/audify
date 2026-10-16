// Testes do item 1.11: pedidos de permissão POR CONTEXTO (sem rajada).
//
// Três frentes cobertas:
//  1. PermissionService — decisões puras testáveis: a política do
//     POST_NOTIFICATIONS (shouldRequestNotification) e os lotes por
//     contexto (cada aba pede só a SUA permissão; notificação só no
//     primeiro play). O caminho "fora do Android" (Platform.isAndroid =
//     false no VM) não toca canal nativo e não lança.
//  2. PlayerProvider — o boot NÃO pede notificação; o primeiro play pede
//     UMA vez; pedido que lança não derruba a reprodução.
//  3. VideoProvider/GalleryProvider — o pedido automático da aba acontece
//     uma única vez por sessão e só quando o acesso ainda falta.
//
// O botão "Permitir" das telas explicativas continua valendo para
// tentativas seguintes (fluxo existente, não coberto aqui).

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/gallery_provider.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/video_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/permission_service.dart';

import 'support/playable_audio_service.dart';

Song _track(String name) =>
    Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

class _FakeSongRepository extends SongRepository {
  final List<Song> assets;
  _FakeSongRepository(this.assets);

  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => assets;
}

class _FakeSessionRepository extends SessionRepository {
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

/// Conta chamadas ao pedido automático da aba (substitui o diálogo do
/// sistema — que não existe no VM).
class _CountingVideoProvider extends VideoProvider {
  int requests = 0;

  @override
  Future<bool> requestAccess() async {
    requests++;
    return false;
  }
}

/// Simula "acesso concedido": o load-base não roda, logo a flag de
/// negação nunca é ligada (estado inicial = não negado).
class _GrantedVideoProvider extends VideoProvider {
  int requests = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> requestAccess() async {
    requests++;
    return true;
  }
}

class _CountingGalleryProvider extends GalleryProvider {
  int requests = 0;

  @override
  Future<bool> requestAccess() async {
    requests++;
    return false;
  }
}

class _GrantedGalleryProvider extends GalleryProvider {
  int requests = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> requestAccess() async {
    requests++;
    return true;
  }
}

PlayerProvider _provider(PlayableAudioService svc,
        {Future<void> Function()? requestNotificationPermission}) =>
    PlayerProvider(
      svc,
      songRepository: _FakeSongRepository(<Song>[
        _track('apple'),
        _track('banana'),
        _track('cherry'),
      ]),
      sessionRepository: _FakeSessionRepository(),
      requestNotificationPermission: requestNotificationPermission,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  group('PermissionService: política de pedidos (1.11)', () {
    test('shouldRequestNotification: Android + 1x/sessão + sem grant', () {
      expect(
        PermissionService.shouldRequestNotification(
          isAndroid: true,
          askedThisSession: false,
          granted: false,
        ),
        isTrue,
      );
      // Fora do Android não há o que pedir.
      expect(
        PermissionService.shouldRequestNotification(
          isAndroid: false,
          askedThisSession: false,
          granted: false,
        ),
        isFalse,
      );
      // Já perguntou nesta sessão = não insiste (evita rajada).
      expect(
        PermissionService.shouldRequestNotification(
          isAndroid: true,
          askedThisSession: true,
          granted: false,
        ),
        isFalse,
      );
      // Já concedido = não abre diálogo à toa.
      expect(
        PermissionService.shouldRequestNotification(
          isAndroid: true,
          askedThisSession: false,
          granted: true,
        ),
        isFalse,
      );
    });

    test('lotes por contexto: cada aba pede só a sua permissão', () {
      expect(
        PermissionService.photosTabPermissions,
        <Permission>[Permission.photos],
      );
      expect(
        PermissionService.photosTabPermissions,
        isNot(contains(Permission.notification)),
      );
      expect(
        PermissionService.videosTabPermissions,
        <Permission>[Permission.videos],
      );
      expect(
        PermissionService.videosTabPermissions,
        isNot(contains(Permission.notification)),
      );
      expect(
        PermissionService.firstPlayNotificationPermissions,
        <Permission>[Permission.notification],
      );
    });

    test('requestNotificationAccess fora do Android não toca canal e '
        'é idempotente (2 chamadas seguidas)', () async {
      // VM de teste = Linux: a função curto-circuita sem MissingPlugin.
      await PermissionService.requestNotificationAccess();
      await PermissionService.requestNotificationAccess();
    });

    test('lotes de aba devolvem bool sem lançar fora do Android', () async {
      expect(await PermissionService.requestPhotosAccess(), isA<bool>());
      expect(await PermissionService.requestVideosAccess(), isA<bool>());
      expect(await PermissionService.hasNotificationAccess(), isA<bool>());
    });
  });

  group('PlayerProvider: POST_NOTIFICATIONS no primeiro play (1.11)', () {
    test('boot não pede; primeiro play pede UMA vez por sessão', () async {
      int asks = 0;
      final PlayerProvider provider = _provider(
        PlayableAudioService(),
        requestNotificationPermission: () async => asks++,
      );
      addTearDown(provider.dispose);

      await provider.init();
      expect(asks, 0, reason: 'o boot só pode pedir áudio (sem rajada)');

      await provider.playVisibleAt(0);
      expect(asks, 1, reason: 'primeiro play = pedido de notificação');

      await provider.playVisibleAt(1);
      await provider.next();
      expect(asks, 1, reason: 'não repete nos plays seguintes');
    });

    test('pedido que lança não derruba a reprodução', () async {
      final PlayerProvider provider = _provider(
        PlayableAudioService(),
        requestNotificationPermission: () async =>
            throw StateError('permission boom'),
      );
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);

      expect(provider.currentSong, isNotNull);
      expect(provider.errorMessage, isNull);
      expect(provider.isPlaying, isTrue);
    });
  });

  group('Aba Vídeos: pedido automático por sessão (1.11)', () {
    test('sem acesso: dispara UMA vez; reabrir a aba não repete', () async {
      final _CountingVideoProvider provider = _CountingVideoProvider();
      addTearDown(provider.dispose);

      await provider.load();
      expect(provider.permissionDenied, isTrue);

      await provider.requestAccessOnTabOpen();
      await provider.requestAccessOnTabOpen();
      expect(provider.requests, 1);
    });

    test('com acesso: não há pedido automático', () async {
      final _GrantedVideoProvider provider = _GrantedVideoProvider();
      addTearDown(provider.dispose);

      await provider.requestAccessOnTabOpen();
      expect(provider.requests, 0);
    });
  });

  group('Aba Galeria: pedido automático por sessão (1.11)', () {
    test('sem acesso: dispara UMA vez; reabrir a aba não repete', () async {
      final _CountingGalleryProvider provider = _CountingGalleryProvider();
      addTearDown(provider.dispose);

      await provider.load();
      expect(provider.permissionDenied, isTrue);

      await provider.requestAccessOnTabOpen();
      await provider.requestAccessOnTabOpen();
      expect(provider.requests, 1);
    });

    test('com acesso: não há pedido automático', () async {
      final _GrantedGalleryProvider provider = _GrantedGalleryProvider();
      addTearDown(provider.dispose);

      await provider.requestAccessOnTabOpen();
      expect(provider.requests, 0);
    });
  });
}
