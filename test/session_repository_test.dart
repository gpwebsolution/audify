// Testes unitários do SessionRepository (persistência da sessão de
// reprodução). Usa SharedPreferences mockado — sem plugins nativos.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/repositories/session_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save + load preserva faixa e posição', () async {
    final SessionRepository repository = SessionRepository();
    final Song song = Song.fromAsset(assetPath: 'assets/songs/faixa.mp3');

    await repository.save(song, const Duration(seconds: 42));
    final (Song?, Duration) restored = await repository.load();

    expect(restored.$1, song);
    expect(restored.$2, const Duration(seconds: 42));
  });

  test('load sem sessão salva retorna (null, zero)', () async {
    final SessionRepository repository = SessionRepository();
    final (Song?, Duration) restored = await repository.load();
    expect(restored.$1, isNull);
    expect(restored.$2, Duration.zero);
  });

  test('save sobrescreve a sessão anterior', () async {
    final SessionRepository repository = SessionRepository();
    await repository.save(
      Song.fromAsset(assetPath: 'assets/songs/a.mp3'),
      const Duration(seconds: 10),
    );
    await repository.save(
      Song.fromAsset(assetPath: 'assets/songs/b.mp3'),
      const Duration(seconds: 20),
    );

    final (Song?, Duration) restored = await repository.load();
    expect(restored.$1!.assetPath, 'assets/songs/b.mp3');
    expect(restored.$2, const Duration(seconds: 20));
  });

  test('dados corrompidos no storage retornam (null, zero) sem lançar',
      () async {
    SharedPreferences.setMockInitialValues({'last_song': '{json invalido'});
    final SessionRepository repository = SessionRepository();
    final (Song?, Duration) restored = await repository.load();
    expect(restored.$1, isNull);
    expect(restored.$2, Duration.zero);
  });
}