import 'package:audify/models/gallery_image_model.dart';
import 'package:audify/models/pdf_file_model.dart';
import 'package:audify/models/song_model.dart';
import 'package:audify/models/video_model.dart';
import 'package:audify/widgets/media_details_sheet.dart';
import 'package:audify/utils/back_action.dart';
import 'package:audify/widgets/selection_bar.dart';
import 'package:audify/widgets/song_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// =============================================================================
// Seleção múltipla (mixin) — a máquina de estados que as 4 abas de mídia
// compartilham. É lógica pura: não precisa de widget.
// =============================================================================

/// Probe que consome o mixin e conta reconstrucoes.
///
/// Fica FORA da arvore de widgets de proposito: `setState` em um `State` que
/// nunca foi montado lanca. O mixin nao depende de `State` justamente por
/// isso — entao um objeto simples exercita toda a logica.
class _SelectionProbe with MediaSelection<String> {
  int rebuilds = 0;

  @override
  void notifyChanged() => rebuilds++;
}

void main() {
  group('MediaSelection', () {
    late _SelectionProbe probe;

    setUp(() => probe = _SelectionProbe());

    test('começa fora do modo seleção e sem itens marcados', () {
      expect(probe.isSelectionMode, isFalse);
      expect(probe.selectionCount, 0);
    });

    test('marcar o primeiro item entra no modo seleção', () {
      probe.toggleSelect('a');
      expect(probe.isSelectionMode, isTrue);
      expect(probe.isSelected('a'), isTrue);
    });

    test('desmarcar o último item sai do modo seleção', () {
      probe.toggleSelect('a');
      probe.toggleSelect('b');
      expect(probe.selectionCount, 2);

      probe.toggleSelect('a');
      probe.toggleSelect('b');
      expect(probe.selectionCount, 0);
      expect(probe.isSelectionMode, isFalse);
    });

    test('cada alteração notifica a UI (para o AnimatedSize reagir)', () {
      final int before = probe.rebuilds;
      probe.toggleSelect('a');
      probe.toggleSelect('b');
      probe.clearSelection();
      expect(probe.rebuilds, before + 3);
    });

    test('clearSelection sem seleção ativa é no-op (não redesenha)', () {
      final int before = probe.rebuilds;
      probe.clearSelection();
      expect(probe.rebuilds, before);
    });

    test('toggleSelectAll marca tudo e um segundo toque desmarca', () {
      const List<String> visible = <String>['a', 'b', 'c'];

      probe.toggleSelectAll(visible);
      expect(probe.selectionCount, 3);
      expect(probe.isSelectionMode, isTrue);

      probe.toggleSelectAll(visible);
      expect(probe.selectionCount, 0);
      expect(probe.isSelectionMode, isFalse);
    });

    test('toggleSelectAll parcial completa a marcação', () {
      probe.toggleSelect('a');
      probe.toggleSelectAll(<String>['a', 'b', 'c']);
      expect(probe.selectionCount, 3);
    });

    test('toggleSelectAll sobre lista vazia não entra no modo seleção', () {
      probe.toggleSelectAll(const <String>[]);
      expect(probe.isSelectionMode, isFalse);
    });

    test('selectedFrom devolve só o que está marcado E visível', () {
      final List<String> universe = <String>['a', 'b', 'c', 'd'];
      probe.toggleSelect('a');
      probe.toggleSelect('c');
      probe.toggleSelect('zz'); // marcado, mas fora da lista visível

      final List<String> result = probe.selectedFrom(universe, (String s) => s);
      expect(result, <String>['a', 'c']);
    });

    test('selectedFrom com nada marcado devolve lista vazia', () {
      expect(probe.selectedFrom(<String>['a', 'b'], (String s) => s), isEmpty);
    });
  });

  // ===========================================================================
  // Painel de detalhes
  // ===========================================================================

  group('MediaDetailsSheet', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    }

    testWidgets('mostra os campos informados', (WidgetTester tester) async {
      await pump(
        tester,
        const MediaDetailsSheet(
          icon: Icons.music_note,
          iconColor: Colors.indigo,
          title: 'Minha faixa',
          subtitle: 'Meu artista',
          rows: <(String?, String?)>[
            ('Título', 'Minha faixa'),
            ('Artista', 'Meu artista'),
            ('Duração', '3:21'),
          ],
        ),
      );

      expect(find.text('Minha faixa'), findsWidgets);
      expect(find.text('Meu artista'), findsWidgets);
      expect(find.text('3:21'), findsOneWidget);
      expect(find.text('Rótulo'), findsNothing);
    });

    testWidgets('omite linha com rótulo ou valor vazio', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        const MediaDetailsSheet(
          icon: Icons.image,
          iconColor: Colors.teal,
          title: 'Foto',
          rows: <(String?, String?)>[
            ('Álbum', null),
            (null, 'valor sem rótulo'),
            ('Extensão', ''),
            ('Tamanho', '2 MB'),
          ],
        ),
      );

      expect(find.text('2 MB'), findsOneWidget);
      expect(find.text('valor sem rótulo'), findsNothing);
    });

    testWidgets('mostra aviso quando não há nada a exibir', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        const MediaDetailsSheet(
          icon: Icons.insert_drive_file,
          iconColor: Colors.grey,
          title: 'Sem dados',
          rows: <(String?, String?)>[('Tudo', null)],
        ),
      );

      expect(
        find.text('Nenhuma informação disponível para este arquivo.'),
        findsOneWidget,
      );
    });

    testWidgets('botão de copiar só aparece com caminho', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        const MediaDetailsSheet(
          icon: Icons.music_note,
          iconColor: Colors.indigo,
          title: 'Sem caminho',
          rows: <(String?, String?)>[('Título', 'x')],
        ),
      );
      expect(find.byIcon(Icons.copy_all_outlined), findsNothing);

      await pump(
        tester,
        const MediaDetailsSheet(
          icon: Icons.music_note,
          iconColor: Colors.indigo,
          title: 'Com caminho',
          path: '/storage/emulated/0/Music/x.mp3',
          rows: <(String?, String?)>[('Título', 'x')],
        ),
      );
      expect(find.byIcon(Icons.copy_all_outlined), findsOneWidget);
    });

    testWidgets('abre a folha de detalhes de música com caminho real', (
      WidgetTester tester,
    ) async {
      // Música embutida no app: sem caminho, sem id — a folha não pode
      // quebrar nem inventar caminho.
      final Song asset = Song.fromAsset(assetPath: 'assets/songs/demo.mp3');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MediaDetailsSheet.showSong(context, asset),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      expect(find.text('Demo'), findsWidgets);
      expect(find.text('Embutida no app'), findsOneWidget);
      // Não há caminho para asset, logo não há botão de copiar.
      expect(find.byIcon(Icons.copy_all_outlined), findsNothing);
    });

    testWidgets('detalhes de vídeo trazem duração, tamanho e caminho', (
      WidgetTester tester,
    ) async {
      final Video video = Video(
        id: 42,
        title: 'Clipe',
        displayName: 'clipe.mp4',
        duration: const Duration(minutes: 2),
        path: '/storage/emulated/0/Movies/clipe.mp4',
        size: 1024 * 1024 * 5,
        dateAdded: 1700000000,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MediaDetailsSheet.showVideo(context, video),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      expect(find.text('02:00'), findsWidgets);
      expect(find.text('5.0 MB'), findsOneWidget);
      expect(find.text('/storage/emulated/0/Movies/clipe.mp4'), findsOneWidget);
      expect(find.text('MP4'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('detalhes de foto com dimensões mostra megapixels', (
      WidgetTester tester,
    ) async {
      const GalleryImage image = GalleryImage(
        id: 7,
        name: 'foto.jpg',
        path: '/storage/emulated/0/DCIM/foto.jpg',
        size: 2048,
        dateAdded: 1700000000,
        width: 4000,
        height: 3000,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MediaDetailsSheet.showImage(context, image),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      expect(find.text('4000 x 3000 px'), findsOneWidget);
      expect(find.text('12.0 MP'), findsOneWidget);
      expect(find.text('JPG'), findsOneWidget);
    });

    testWidgets('detalhes de PDF do SAF marcam a origem', (
      WidgetTester tester,
    ) async {
      final PdfFile picked = PdfFile.fromPicked(
        path: '/storage/emulated/0/Downloads/doc.pdf',
        name: 'doc.pdf',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => MediaDetailsSheet.showPdf(context, picked),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      expect(find.text('Seletor de arquivos'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
    });
  });

  // ===========================================================================
  // Barra de seleção em lote
  // ===========================================================================

  group('SelectionBar', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    }

    testWidgets('sem onDelete nem ações, a barra fica com 2 controles', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        SelectionBar(
          label: '1 selecionado',
          onSelectAll: () {},
          onClear: () {},
        ),
      );
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      // Sem o que mostrar no menu, o menu não aparece — botão morto é pior
      // que botão ausente.
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byIcon(Icons.select_all), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('ações extras vão para o menu de 3 pontinhos', (
      WidgetTester tester,
    ) async {
      int share = 0;
      await pump(
        tester,
        SelectionBar(
          label: '2 selecionadas',
          onSelectAll: () {},
          onClear: () {},
          actions: <SelectionAction>[
            SelectionAction(
              icon: Icons.share_outlined,
              label: 'Compartilhar selecionadas',
              onPressed: () => share++,
            ),
            SelectionAction(
              icon: Icons.swap_horiz,
              label: 'Inverter seleção',
              onPressed: () {},
            ),
          ],
        ),
      );

      // Nada de ícone de ação espalhado pela barra: só o menu.
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsNothing);

      // Abrindo o menu, as ações aparecem COM RÓTULO (não adivinháveis).
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Compartilhar selecionadas'), findsOneWidget);
      expect(find.text('Inverter seleção'), findsOneWidget);

      await tester.tap(find.text('Compartilhar selecionadas'));
      await tester.pumpAndSettle();
      expect(share, 1);
    });

    testWidgets('ação desabilitada aparece esmaecida, não some', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        SelectionBar(
          label: '3 selecionados',
          onSelectAll: () {},
          onClear: () {},
          actions: <SelectionAction>[
            SelectionAction(
              icon: Icons.info_outline,
              label: 'Detalhes (selecione 1 arquivo)',
              onPressed: null,
            ),
          ],
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      // Visível para o usuário entender que o recurso existe.
      expect(find.text('Detalhes (selecione 1 arquivo)'), findsOneWidget);
    });

    testWidgets('com exclusão mas sem ações, o menu ainda existe', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        SelectionBar(
          label: '1 selecionada',
          onSelectAll: () {},
          onClear: () {},
          onDelete: () {},
        ),
      );
      // O menu existe porque tem o que mostrar: excluir.
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });
  });

  // ===========================================================================
  // Troca animada de toolbar
  // ===========================================================================

  group('AnimatedToolbarSwap', () {
    testWidgets('começa na toolbar normal e troca para a de seleção', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: _SwapHost())),
      );
      expect(find.text('normal'), findsOneWidget);
      expect(find.text('selecao'), findsNothing);

      await tester.tap(find.text('alternar'));
      await tester.pumpAndSettle();

      expect(find.text('selecao'), findsOneWidget);
      expect(find.text('normal'), findsNothing);
    });

    testWidgets('com toolbar vazia, a altura vai de 0 para a da barra', (
      WidgetTester tester,
    ) async {
      // Cenário real das abas de Vídeo/Galeria/PDF: não existe toolbar
      // normal, então o espaço da barra tem que mesmo ser liberado quando o
      // modo seleção termina (senão sobra um buraco na tela).
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: _EmptyToolbarHost())),
      );
      expect(
        tester.getSize(find.byType(AnimatedToolbarSwap)).height,
        lessThan(1),
      );

      await tester.tap(find.text('alternar'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(AnimatedToolbarSwap)).height,
        greaterThan(20),
      );

      await tester.tap(find.text('alternar'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(AnimatedToolbarSwap)).height,
        lessThan(1),
      );
    });
  });

  // =============================================================================
  // Regressão: o botão de ações (⋮) precisa EXISTIR nos tiles.
  //
  // O long-press passou a marcar em vez de abrir o menu, então as ações por item
  // só continuam acessíveis por um botão visível. Quando esse botão sumiu do card
  // de vídeo, compartilhar/detalhes/excluir um vídeo isolado ficaram
  // inalcançáveis — e o analyzer não reclamou, porque o campo era público.
  // Um teste que toca no ícone é o que pega esse tipo de erro.
  // =============================================================================

  group('botão de ações acessível', () {
    testWidgets('SongListTile mostra o botão ⋮ fora do modo seleção', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListTile(
              song: Song.fromAsset(assetPath: 'assets/songs/demo.mp3'),
              isCurrent: false,
              isPlaying: false,
              onTap: () {},
              onMenuTap: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('SongListTile esconde o ⋮ no modo seleção', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListTile(
              song: Song.fromAsset(assetPath: 'assets/songs/demo.mp3'),
              isCurrent: false,
              isPlaying: false,
              onTap: () {},
              selectionMode: true,
              onMenuTap: () {},
            ),
          ),
        ),
      );

      // No modo seleção o polegar é da ação em lote.
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('o botão ⋮ dispara a ação da faixa', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListTile(
              song: Song.fromAsset(assetPath: 'assets/songs/demo.mp3'),
              isCurrent: false,
              isPlaying: false,
              onTap: () {},
              onMenuTap: () => opened++,
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('o alvo de toque do ⋮ tem 48dp', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SongListTile(
              song: Song.fromAsset(assetPath: 'assets/songs/demo.mp3'),
              isCurrent: false,
              isPlaying: false,
              onTap: () {},
              onMenuTap: () {},
            ),
          ),
        ),
      );

      final Size size = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.more_vert),
          matching: find.byType(IconButton),
        ),
      );
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('resolveBack', () {
    final DateTime t0 = DateTime(2026, 1, 1, 12);

    test('em outra aba, volta para a primeira em vez de sair', () {
      final BackDecision d = resolveBack(
        currentTabIndex: 3,
        now: t0,
        lastPress: t0,
      );
      expect(d.action, BackAction.goToFirstTab);
      // Trocar de aba zera a janela: um toque seguinte na primeira aba não pode
      // sair por herança do toque que só mudou de aba.
      expect(d.nextLastPress, isNull);
    });

    test('na primeira aba, o primeiro toque só avisa', () {
      final BackDecision d = resolveBack(
        currentTabIndex: 0,
        now: t0,
        lastPress: null,
      );
      expect(d.action, BackAction.warnThenExit);
      expect(d.nextLastPress, t0);
    });

    test('segundo toque dentro da janela encerra o app', () {
      final BackDecision d = resolveBack(
        currentTabIndex: 0,
        now: t0.add(const Duration(milliseconds: 800)),
        lastPress: t0,
      );
      expect(d.action, BackAction.exit);
    });

    test('segundo toque PASSADO da janela volta a só avisar', () {
      final BackDecision d = resolveBack(
        currentTabIndex: 0,
        now: t0.add(const Duration(seconds: 5)),
        lastPress: t0,
      );
      // Passou da janela, é um toque novo: o app NÃO fecha.
      expect(d.action, BackAction.warnThenExit);
      expect(d.nextLastPress, t0.add(const Duration(seconds: 5)));
    });

    test('três toques rápidos: avisa, sai, e não reabre a janela', () {
      final BackDecision first = resolveBack(
        currentTabIndex: 0,
        now: t0,
        lastPress: null,
      );
      expect(first.action, BackAction.warnThenExit);

      final BackDecision second = resolveBack(
        currentTabIndex: 0,
        now: t0.add(const Duration(milliseconds: 300)),
        lastPress: first.nextLastPress,
      );
      expect(second.action, BackAction.exit);
    });

    test('voltar para a primeira aba a partir da última', () {
      for (final int index in <int>[1, 2, 3, 4, 5, 6]) {
        expect(
          resolveBack(currentTabIndex: index, now: t0).action,
          BackAction.goToFirstTab,
          reason: 'aba $index deveria voltar para a primeira',
        );
      }
    });
  });
}

/// Host da troca de toolbar: botão alterna o modo seleção.
class _SwapHost extends StatefulWidget {
  const _SwapHost();

  @override
  State<_SwapHost> createState() => _SwapHostSwapState();
}

class _SwapHostSwapState extends State<_SwapHost> with MediaSelection<bool> {
  @override
  void notifyChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: const SelectionBar(
            label: 'selecao',
            onSelectAll: _noop,
            onClear: _noop,
          ),
          toolbar: const SizedBox(
            height: 48,
            child: Center(child: Text('normal')),
          ),
        ),
        TextButton(
          onPressed: () => toggleSelect(true),
          child: const Text('alternar'),
        ),
      ],
    );
  }
}

/// Host com toolbar vazia (o caso das abas de mídia sem toolbar normal).
class _EmptyToolbarHost extends StatefulWidget {
  const _EmptyToolbarHost();

  @override
  State<_EmptyToolbarHost> createState() => _EmptyToolbarHostState();
}

class _EmptyToolbarHostState extends State<_EmptyToolbarHost>
    with MediaSelection<bool> {
  @override
  void notifyChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: const SelectionBar(
            label: 'selecao',
            onSelectAll: _noop,
            onClear: _noop,
          ),
          toolbar: const SizedBox.shrink(),
        ),
        TextButton(
          onPressed: () => toggleSelect(true),
          child: const Text('alternar'),
        ),
      ],
    );
  }
}

void _noop() {}

// =============================================================================
// Botão voltar na raiz do app.
// =============================================================================
