import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'providers/file_provider.dart';
import 'providers/gallery_provider.dart';
import 'services/error_log_service.dart';
import 'services/pdf_favorites_service.dart';
import 'providers/player_provider.dart';
import 'providers/pdf_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/video_provider.dart';
import 'screens/main_screen.dart';
import 'services/audio_service.dart';
import 'theme/app_theme.dart';

void main() {
  // Garante o binding antes de qualquer plugin (chamado dentro da zona
  // guardada para que falhas do boot também sejam logadas).
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // ---- Log de erros local (crash_log.txt no aparelho) ----
      // Precisa existir ANTES de qualquer coisa para capturar falhas do
      // próprio boot. 100% offline: nada é enviado para fora.
      await ErrorLogService.init();
      FlutterError.onError = (FlutterErrorDetails details) {
        // Em debug mantém o comportamento padrão (console + tela vermelha);
        // em release apenas registra sem derrubar o app.
        FlutterError.presentError(details);
        ErrorLogService.logSync('flutter', details.exception, details.stack);
      };
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        ErrorLogService.logSync('platform', error, stack);
        // true = tratado; impede que a exceção assíncrona mate o processo.
        return true;
      };

      await _bootstrap();
    },
    (Object error, StackTrace stack) {
      // Qualquer exceção não tratada da zona cai aqui — logada, nunca
      // crash silencioso sem rastro.
      ErrorLogService.logSync('zone', error, stack);
    },
  );
}

/// Inicialização real do app. Cada etapa pesada é isolada: se o
/// audio_service falhar (canal nativo morto pós-crash do processo,
/// fabricante com restrição), o app AINDA ABRE — só perde a notificação
/// de mídia. Antes, uma exceção aqui = app que "não abre mais".
Future<void> _bootstrap() async {
  // Preferências carregadas ANTES do runApp para o tema correto já no
  // primeiro frame (sem flash de tema errado).
  final SettingsProvider settingsProvider = SettingsProvider();
  try {
    await settingsProvider.load();
  } catch (e, s) {
    ErrorLogService.logSync('boot', 'Falha ao carregar preferências: $e', s);
  }

  // Serviço de áudio com MediaSession: notificação de mídia e controles
  // na tela de bloqueio. Tenta a config completa; em caso de falha,
  // tenta uma config mínima; em último caso segue SEM segundo plano.
  AudioService audioService;
  try {
    audioService = await audio_service.AudioService.init(
      builder: () => AudioService(),
      config: const audio_service.AudioServiceConfig(
        androidNotificationChannelId: 'com.example.music_app.audio',
        androidNotificationChannelName: 'Audify',
        // false: ao pausar, o serviço PERMANECE em foreground. Com `true`
        // o Android rebaixa o serviço e aparelhos Xiaomi/Samsung/Motorola
        // matam o processo pouco depois — perdendo a notificação e a
        // posição (principal causa de reprodução morrendo em segundo plano).
        androidStopForegroundOnPause: false,
        // Ongoing=true é rejeitado pelo próprio package quando
        // stopForegroundOnPause=false (assert). Com ongoing=false, deslizar
        // a notificação dispara onClose -> stop() limpo do player.
        androidNotificationIcon: 'mipmap/launcher_icon',
      ),
    );
  } catch (e, s) {
    ErrorLogService.logSync('boot', 'AudioService.init falhou: $e', s);
    audioService = AudioService.noop();
  }

  runApp(
    MultiProvider(
      providers: [
        // Tema persistido (claro/escuro/sistema).
        ChangeNotifierProvider.value(value: settingsProvider),
        // Player: único provider de áudio; o AudioService é criado junto.
        ChangeNotifierProvider(
          create: (_) =>
              PlayerProvider(audioService, settings: settingsProvider),
        ),
        // Playlists (banco sqflite) — depende do player para tocar filas.
        ChangeNotifierProxyProvider<PlayerProvider, PlaylistProvider>(
          create: (context) => PlaylistProvider(context.read<PlayerProvider>()),
          update: (context, player, playlist) =>
              playlist ?? PlaylistProvider(player),
        ),
        // Biblioteca de vídeos (MediaStore via canal nativo).
        ChangeNotifierProvider(create: (_) => VideoProvider()),
        // Galeria de fotos (MediaStore via canal nativo).
        ChangeNotifierProvider(create: (_) => GalleryProvider()),
        // PDFs (MediaStore + seletor SAF).
        ChangeNotifierProvider(create: (_) => PdfProvider()),
        // Gerenciador de arquivos (aba Arquivos).
        ChangeNotifierProvider(create: (_) => FileProvider()),
        // Favoritos de PDFs (SharedPreferences).
        ChangeNotifierProvider(create: (_) => PdfFavoritesService()),
      ],
      child: const MusicApp(),
    ),
  );
}

/// Raiz do app: MaterialApp com tema dinâmico conforme as preferências.
class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return MaterialApp(
      title: 'Audify',
      debugShowCheckedModeBanner: false,
      // UI do app em pt-BR; componentes do sistema (licenças, seleção de
      // texto, dialogs de plugins) também localizados.
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: settings.themeMode,
      home: const MainScreen(),
    );
  }
}
