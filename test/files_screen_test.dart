// Item 6.2 — teste de caracterização da FilesScreen ANTES da extração dos
// widgets privados (_FileListTile, _NewFileDialog, _EmptyState, ...).
//
// Em host Platform.isAndroid é false: o provider carrega vazio e o corpo é o
// estado "Gerenciador disponível apenas no Android". O que este teste protege
// é a casca alcançável sem Android: barra de busca + escopo, breadcrumb,
// toolbars, menu de opções (com o badge da lixeira) e os diálogos dele.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/providers/file_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/screens/files_screen.dart';
import 'package:audify/models/file_item.dart';
import 'package:audify/widgets/destination_picker.dart';
import 'package:audify/widgets/file_screen_states.dart';
import 'package:audify/widgets/file_tiles.dart';
import 'package:audify/screens/trash_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
// A interface do path_provider é transitiva do path_provider direto do
// pubspec; o teste injeta o fake por ela (padrão suportado pelo plugin).
// ignore_for_file: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Fake do path_provider — a lixeira lida com o diretório de suporte e em
/// host não há plugin registrado.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<FileProvider> pumpScreen(WidgetTester tester) async {
    // TrashScreen (destino do menu) lê SettingsProvider; FileProvider cobre a
    // própria tela.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    addTearDown(settings.dispose);
    final PathProviderPlatform previous = PathProviderPlatform.instance;
    final Directory support =
        Directory.systemTemp.createTempSync('audify_files_ui');
    addTearDown(() {
      support.deleteSync(recursive: true);
      PathProviderPlatform.instance = previous;
    });
    PathProviderPlatform.instance = _FakePathProvider(support.path);
    final FileProvider provider = FileProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<FileProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const MaterialApp(home: Scaffold(body: FilesScreen())),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('renderiza casca completa e o estado vazio do host', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.text('Buscar nesta pasta e subpastas…'),
      findsOneWidget,
    );
    expect(
      find.text('Gerenciador disponível apenas no Android.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.byTooltip('Filtrar por tipo'), findsOneWidget);
    expect(find.byTooltip('Lista / Grade'), findsOneWidget);
    expect(find.byTooltip('Mais opções'), findsOneWidget);
  });

  testWidgets('escopo da busca alterna o hint e o tooltip', (
    WidgetTester tester,
  ) async {
    final FileProvider provider = await pumpScreen(tester);

    expect(provider.globalSearch, isFalse);

    await tester.tap(find.byTooltip('Escopo: pasta atual (toque p/ ampliar)'));
    await tester.pumpAndSettle();

    expect(provider.globalSearch, isTrue);
    expect(find.text('Buscar em todo o aparelho…'), findsOneWidget);
    expect(
      find.byTooltip('Escopo: todo o aparelho (toque p/ restringir)'),
      findsOneWidget,
    );
  });

  testWidgets('digitar mostra o X de limpar; limpar zera o campo', (
    WidgetTester tester,
  ) async {
    final FileProvider provider = await pumpScreen(tester);

    expect(find.byTooltip('Limpar busca'), findsNothing);

    await tester.enterText(find.byType(TextField), 'ndc');
    // setSearchQuery agenda um debounce de 350 ms; o _runSearch roda a busca
    // em isolate (compute), que só termina fora da zona fake do teste.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(provider.searchQuery, 'ndc');

    await tester.tap(find.byTooltip('Limpar busca'));
    await tester.pumpAndSettle();
    expect(provider.searchQuery, isEmpty);
    expect(find.byTooltip('Limpar busca'), findsNothing);
  });

  testWidgets('menu Mais opções abre o diálogo de nova pasta', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.byTooltip('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.text('Nova pasta'), findsOneWidget);
    expect(find.text('Novo arquivo de texto'), findsOneWidget);
    expect(find.text('Lixeira'), findsOneWidget);
    // Badge da lixeira: vazia mostra "vazia" no subtítulo do menu.
    expect(find.text('vazia'), findsOneWidget);

    await tester.tap(find.text('Nova pasta'));
    await tester.pumpAndSettle();

    expect(find.text('Nome da pasta'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Criar'), findsOneWidget);
  });

  testWidgets('diálogo de novo arquivo: casca, extensões e validação', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.byTooltip('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo arquivo de texto'));
    await tester.pumpAndSettle();

    // Casca do diálogo (antes da extração do _NewFileDialog).
    expect(find.text('Novo arquivo de texto'), findsOneWidget);
    expect(find.text('Nome'), findsOneWidget);
    expect(find.text('index'), findsOneWidget); // hintText
    expect(find.text('Criar e editar'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);

    // Lista de extensões aceitas no dropdown.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('.txt'), findsOneWidget);
    // '.html' aparece no item do menu e no botão (valor selecionado).
    expect(find.text('.html'), findsWidgets);
    expect(find.text('.md'), findsOneWidget);
    // Fecha o menu sem escolher.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    // Nome inválido: erro aparece e o diálogo continua aberto.
    // O TextField é escopado ao diálogo — a tela tem o da busca também.
    final Finder dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'a/b');
    await tester.tap(find.text('Criar e editar'));
    await tester.pumpAndSettle();
    expect(
      find.text('O nome não pode conter "/" — crie uma pasta se quiser '
          'organizar.'),
      findsOneWidget,
    );
    expect(find.text('Criar e editar'), findsOneWidget);
  });

  testWidgets('menu leva à tela da lixeira (estado vazio no host)', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.byTooltip('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lixeira'));
    await tester.pumpAndSettle();

    expect(find.byType(TrashScreen), findsOneWidget);
    // Volta para a tela raiz — o Navigator do teste fica limpo.
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator),
    );
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.byType(TrashScreen), findsNothing);
  });

  group('widgets extraídos (6.2)', () {
    FileItem fileItem({
      String name = 'foto.jpg',
      FileType type = FileType.image,
      int size = 1024,
      bool isDirectory = false,
    }) => FileItem(
      path: '/storage/emulated/0/$name',
      name: name,
      type: type,
      size: size,
      dateModified: 0,
      dateCreated: 0,
      isDirectory: isDirectory,
      extension: isDirectory ? '' : (name.contains('.') ? name.split('.').last : ''),
    );

    testWidgets('FileListTile: nome, seleção, toque e long-press', (t) async {
      int taps = 0;
      int longPresses = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileListTile(
              item: fileItem(name: 'relatorio.pdf', type: FileType.pdf, size: 2048),
              isSelected: true,
              selectionMode: true,
              onTap: () => taps++,
              onLongPress: () => longPresses++,
            ),
          ),
        ),
      );

      expect(find.text('relatorio.pdf'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);

      await t.tap(find.text('relatorio.pdf'));
      expect(taps, 1);
      // Com seleção, o checkbox dispara o long-press (mesma ação da tela).
      await t.tap(find.byType(Checkbox));
      expect(longPresses, 1);
    });

    testWidgets('FileGridTile: nome e "Pasta" para diretório', (t) async {
      int taps = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileGridTile(
              item: fileItem(name: 'Músicas', isDirectory: true),
              isSelected: false,
              selectionMode: false,
              onTap: () => taps++,
              onLongPress: () {},
            ),
          ),
        ),
      );

      expect(find.text('Músicas'), findsOneWidget);
      expect(find.text('Pasta'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);

      await t.tap(find.text('Músicas'));
      expect(taps, 1);
    });

    testWidgets('FileThumbnail: diretório, genérico e vídeo (fallback)', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: FileThumbnail(item: fileItem(name: 'Docs', isDirectory: true)),
                ),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: FileThumbnail(item: fileItem(name: 'musica.mp3', type: FileType.audio)),
                ),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: FileThumbnail(item: fileItem(name: 'clipe.mp4', type: FileType.video)),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.byIcon(FileTypeMap.iconForType(FileType.audio)), findsOneWidget);
      // Vídeo: canal nativo inexistente em host → getThumbnail devolve null
      // → o FutureBuilder cai no ícone por extensão.
      expect(find.byIcon(FileTypeMap.iconForType(FileType.video)), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('DestinationPicker: lista subpastas e fecha Selecionar', (
      t,
    ) async {
      final Directory root = Directory.systemTemp.createTempSync('audify_picker');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/Trabalho').createSync();

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => DestinationPicker(initialPath: root.path),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('abrir'));
      // O spinner é infinito: pumpAndSettle nunca terminaria. Pumps datados
      // cobrem só a animação da rota do diálogo.
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));

      expect(find.text('Escolher destino'), findsOneWidget);
      expect(find.byTooltip('Subir um nível'), findsOneWidget);
      expect(find.text('Selecionar esta pasta'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // O load usa compute (isolate) — só termina fora da zona fake.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('Trabalho'), findsOneWidget);
      expect(find.text('Nenhuma subpasta aqui.'), findsNothing);

      await t.tap(find.text('Selecionar esta pasta'));
      // Spinner sumiu — agora o settle da saída é seguro.
      await t.pumpAndSettle();
      expect(find.text('Escolher destino'), findsNothing);
    });

    testWidgets('AllFilesAccessState: ação do botão de concessão', (t) async {
      int requests = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AllFilesAccessState(onRequest: () => requests++),
          ),
        ),
      );

      expect(find.textContaining('Todos os arquivos'), findsOneWidget);
      await t.tap(find.text('Conceder acesso'));
      expect(requests, 1);
    });

    testWidgets('EmptyState: ícone e mensagem', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: EmptyState(icon: Icons.folder_off, message: 'Nada por aqui.')),
        ),
      );
      expect(find.byIcon(Icons.folder_off), findsOneWidget);
      expect(find.text('Nada por aqui.'), findsOneWidget);
    });
  });
}
