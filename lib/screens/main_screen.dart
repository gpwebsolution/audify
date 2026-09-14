import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/file_provider.dart';
import '../providers/gallery_provider.dart';
import '../providers/pdf_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/video_provider.dart';
import 'files_screen.dart';
import 'gallery_screen.dart';
import 'music_screen.dart';
import 'pdf_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';
import 'videos_screen.dart';
import '../widgets/player_controls.dart';

/// Abas do menu lateral (drawer).
enum MainTab { music, videos, gallery, files, pdfs, playlists, settings }

/// Shell principal do app: menu hambúrguer lateral (drawer) + mini player
/// fixo no rodapé.
///
/// As abas ficam em [IndexedStack] — cada uma preserva seu estado (busca,
/// rolagem) ao trocar de aba, evitando rebuilds desnecessários.
///
/// Observa o ciclo de vida do app ([WidgetsBindingObserver]): ao ir para
/// segundo plano salva a sessão do player; ao voltar, re-sincroniza a UI
/// com o estado real do áudio (posição/status podem ter mudado pela
/// notificação/tela de bloqueio enquanto o app estava escondido).
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Guard de context across async gaps: leia os providers ANTES de
    // qualquer await.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // Indo para segundo plano / processo sendo fechado: persiste
        // "continuar de onde parou" imediatamente (o throttle de 5s pode
        // não ter disparado).
        context.read<PlayerProvider>().onAppPaused();
      case AppLifecycleState.resumed:
        // De volta ao primeiro plano: revalida permissões que podem ter
        // mudado nas Configurações do sistema e ressincroniza o estado
        // do player com o AudioHandler (cobrindo o caso de o serviço ter
        // continuado vivo enquanto a Activity foi recriada).
        context.read<PlayerProvider>().onAppResumed();
      case AppLifecycleState.inactive:
        break;
    }
  }

  static const List<Widget> _tabs = [
    MusicScreen(),
    VideosScreen(),
    GalleryScreen(),
    FilesScreen(),
    PdfScreen(),
    PlaylistsScreen(),
    SettingsScreen(),
  ];

  static const List<String> _titles = [
    'Audify',
    'Vídeos',
    'Galeria',
    'Arquivos',
    'PDFs',
    'Playlists',
    'Configurações',
  ];

  /// Troca de aba e recarrega bibliotecas que podem ter carregado vazias
  /// antes da permissão de mídia ser concedida (galeria/vídeos/PDFs).
  Future<void> _selectTab(int index) async {
    setState(() => _currentIndex = index);

    switch (MainTab.values[index]) {
      case MainTab.videos:
        context.read<VideoProvider>().load();
      case MainTab.gallery:
        context.read<GalleryProvider>().load();
      case MainTab.files:
        await context.read<FileProvider>().refreshVolumes();
      case MainTab.pdfs:
        context.read<PdfProvider>().load();
      case MainTab.music:
      case MainTab.playlists:
      case MainTab.settings:
        break;
    }
  }

  /// Dialog de criação de playlist (nome).
  Future<void> _createPlaylist(BuildContext context) async {
    final PlaylistProvider provider = context.read<PlaylistProvider>();
    final TextEditingController controller = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nova playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nome da playlist',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;

    final bool created = await provider.create(name);
    if (!created && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Já existe uma playlist com o nome "$name".'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
      ),
      body: Column(
        children: [
          // ---- Abas (IndexedStack preserva estado de cada uma) ----
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: _tabs,
            ),
          ),
          // ---- Mini player fixo no rodapé ----
          const PlayerControls(),
        ],
      ),
      // ---- FAB de criar playlist (apenas na aba Playlists) ----
      floatingActionButton: _currentIndex == MainTab.playlists.index
          ? FloatingActionButton(
              tooltip: 'Nova playlist',
              onPressed: () => _createPlaylist(context),
              child: const Icon(Icons.add),
            )
          : null,
      // ---- Menu hambúrguer lateral com a logo do app no topo ----
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              // Logo + nome do app no topo do menu.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.asset(
                        'assets/images/audify.png',
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.music_note,
                          size: 56,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      'Audify',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _DrawerItem(
                      icon: Icons.music_note_outlined,
                      selectedIcon: Icons.music_note,
                      label: 'Música',
                      selected: _currentIndex == MainTab.music.index,
                      onTap: () => _onDrawerTap(MainTab.music.index),
                    ),
                    _DrawerItem(
                      icon: Icons.videocam_outlined,
                      selectedIcon: Icons.videocam,
                      label: 'Vídeos',
                      selected: _currentIndex == MainTab.videos.index,
                      onTap: () => _onDrawerTap(MainTab.videos.index),
                    ),
                    _DrawerItem(
                      icon: Icons.photo_library_outlined,
                      selectedIcon: Icons.photo_library,
                      label: 'Galeria',
                      selected: _currentIndex == MainTab.gallery.index,
                      onTap: () => _onDrawerTap(MainTab.gallery.index),
                    ),
                    _DrawerItem(
                      icon: Icons.folder_outlined,
                      selectedIcon: Icons.folder,
                      label: 'Arquivos',
                      selected: _currentIndex == MainTab.files.index,
                      onTap: () => _onDrawerTap(MainTab.files.index),
                    ),
                    _DrawerItem(
                      icon: Icons.picture_as_pdf_outlined,
                      selectedIcon: Icons.picture_as_pdf,
                      label: 'PDFs',
                      selected: _currentIndex == MainTab.pdfs.index,
                      onTap: () => _onDrawerTap(MainTab.pdfs.index),
                    ),
                    _DrawerItem(
                      icon: Icons.queue_music_outlined,
                      selectedIcon: Icons.queue_music,
                      label: 'Playlists',
                      selected: _currentIndex == MainTab.playlists.index,
                      onTap: () => _onDrawerTap(MainTab.playlists.index),
                    ),
                    _DrawerItem(
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings,
                      label: 'Configurações',
                      selected: _currentIndex == MainTab.settings.index,
                      onTap: () => _onDrawerTap(MainTab.settings.index),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fecha o menu e troca de aba.
  void _onDrawerTap(int index) {
    Navigator.of(context).pop();
    _selectTab(index);
  }
}

/// Item do menu lateral: ícone + rótulo, com estado selecionado.
class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(selected ? selectedIcon : icon),
      title: Text(label),
      selected: selected,
      selectedTileColor: colors.secondaryContainer.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onTap: onTap,
    );
  }
}