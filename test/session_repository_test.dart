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


  test('clear apaga a sessao salva (faixa excluida do aparelho)', () async {
    SharedPreferences.setMockInitialValues({});
    final SessionRepository repository = SessionRepository();
    await repository.save(
      Song.fromAsset(assetPath: 'assets/songs/a.mp3'),
      const Duration(seconds: 42),
    );
    expect((await repository.load()).$1, isNotNull);

    await repository.clear();

    final (Song?, Duration) afterClear = await repository.load();
    expect(afterClear.$1, isNull);
    expect(afterClear.$2, Duration.zero);
  });

  test('clear em sessao inexistente nao lanca', () async {
    SharedPreferences.setMockInitialValues({});
    final SessionRepository repository = SessionRepository();
    await repository.clear();
    expect((await repository.load()).$1, isNull);
  });

  // ------------------------------------------------------------------
  // Fila ativa (item 1.6): salvar/restaurar os ids da fila + índice.
  // ------------------------------------------------------------------

  test('saveQueue + loadQueue preserva ordem dos ids e índice', () async {
    final SessionRepository repository = SessionRepository();
    await repository.saveQueue(['c', 'a', 'b', 'd'], 2);

    final (List<String> ids, int index) = await repository.loadQueue();
    expect(ids, ['c', 'a', 'b', 'd']);
    expect(index, 2);
  });

  test('loadQueue sem fila salva devolve (vazia, -1)', () async {
    final SessionRepository repository = SessionRepository();
    final (List<String> ids, int index) = await repository.loadQueue();
    expect(ids, isEmpty);
    expect(index, -1);
  });

  test('saveQueue com lista vazia apaga a fila salva', () async {
    final SessionRepository repository = SessionRepository();
    await repository.saveQueue(['a', 'b'], 1);
    await repository.saveQueue(const [], 0);

    final (List<String> ids, _) = await repository.loadQueue();
    expect(ids, isEmpty);
  });

  test('fila maior que o teto guarda janela centrada na faixa atual',
      () async {
    final SessionRepository repository = SessionRepository();
    final List<String> ids =
        List<String>.generate(1000, (int i) => 'id-$i');
    await repository.saveQueue(ids, 500);

    final (List<String> saved, int index) = await repository.loadQueue();
    expect(saved.length, SessionRepository.maxQueueIds);
    // A faixa corrente continua acessível: o índice salvo aponta
    // para ela DENTRO da janela.
    expect(saved[index], 'id-500');
    // A janela é contígua e preserva a ordem original.
    expect(saved.first, ids[250]);
  });

  test('índice salvo fora do intervalo é clampado; storage corrompido '
      'devolve -1', () async {
    final SessionRepository repository = SessionRepository();
    // Índice maior que a fila: grava já clampado (fila encurtou entre
    // gravar e o teto) — a leitura devolve um índice válido.
    await repository.saveQueue(['a', 'b'], 99);
    final (_, int clamped) = await repository.loadQueue();
    expect(clamped, 1);

    // Índice gravado apontando além da lista (storage adulterado):
    // loadQueue devolve -1 em vez de estourar.
    SharedPreferences.setMockInitialValues({
      'queue_ids': '["a","b"]',
      'queue_index': 42,
    });
    final (_, int index) = await repository.loadQueue();
    expect(index, -1);
  });

  test('queue_ids corrompido devolve (vazia, -1) sem lançar', () async {
    SharedPreferences.setMockInitialValues({'queue_ids': '{quebrado'});
    final SessionRepository repository = SessionRepository();
    final (List<String> ids, int index) = await repository.loadQueue();
    expect(ids, isEmpty);
    expect(index, -1);
  });

  test('clear apaga também a fila salva', () async {
    final SessionRepository repository = SessionRepository();
    await repository.saveQueue(['a', 'b', 'c'], 1);

    await repository.clear();

    final (List<String> ids, _) = await repository.loadQueue();
    expect(ids, isEmpty);
    expect((await repository.load()).$1, isNull);
  });
}
