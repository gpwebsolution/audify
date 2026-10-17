// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Audify';

  @override
  String get aboutSubtitle =>
      'Player de mídia local — músicas, vídeos, fotos e PDFs.\nFeito por GpWebSolution';

  @override
  String aboutVersion(String version) {
    return 'Versão $version';
  }

  @override
  String get addButton => 'Adicionar';

  @override
  String addedManyToPlaylist(num count, Object name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count adicionadas a \"$name\"',
      one: '$count adicionada a \"$name\"',
    );
    return '$_temp0';
  }

  @override
  String addedPartialToPlaylist(int added, int total, String name) {
    return '$added de $total adicionadas a \"$name\"';
  }

  @override
  String addedToPlaylist(String name) {
    return 'Adicionada a \"$name\"';
  }

  @override
  String get addToPlaylist => 'Adicionar à playlist';

  @override
  String get allowBtn => 'Permitir';

  @override
  String get appearanceTitle => 'Aparência';

  @override
  String get atTrackEnd => 'Ao fim da faixa';

  @override
  String get atTrackEndSub =>
      'Para no fim desta faixa, sem pular para a próxima';

  @override
  String get batterySub =>
      'Recomendado: sem isso, Xiaomi/Samsung/Motorola podem parar a música em segundo plano.';

  @override
  String get batteryTitle => 'Ignorar otimização de bateria';

  @override
  String get cancel => 'Cancelar';

  @override
  String get clearButton => 'Limpar';

  @override
  String get clearSearchTooltip => 'Limpar busca';

  @override
  String get closeButton => 'Fechar';

  @override
  String get collapseTooltip => 'Recolher';

  @override
  String get crossfadeDirect => 'Troca de faixa direta (padrão).';

  @override
  String crossfadeOverlap(int n) {
    return 'Nos últimos ${n}s da faixa e nos primeiros ${n}s da próxima, o volume faz a transição.';
  }

  @override
  String get crossfadeSubtitle =>
      'Transição suave entre faixas — o fim da atual cai e a próxima sobe em volume (sem intervalo).';

  @override
  String get crossfadeTitle => 'Crossfade';

  @override
  String get customSleep => 'Personalizado';

  @override
  String get customSleepSub => 'De 1 a 720 minutos';

  @override
  String get customTimerTitle => 'Timer personalizado';

  @override
  String get deleteFromDevice => 'Excluir do aparelho';

  @override
  String deleteSubtitle(String title) {
    return '$title • o Android pedirá confirmação';
  }

  @override
  String get deleteTrackGoneSub => 'Some da lista, da fila e das playlists';

  @override
  String get details => 'Detalhes';

  @override
  String get detailsSub => 'Álbum, artista, tamanho e caminho';

  @override
  String get emptyNoMusic =>
      'Nenhuma música encontrada.\nAdicione arquivos .mp3 em assets/songs/ ou no aparelho.';

  @override
  String emptyNoResults(String query) {
    return 'Nenhum resultado para \"$query\".';
  }

  @override
  String get emptyPermissionDenied =>
      'Permissão de acesso às músicas negada.\nPermita acima para ver as músicas do aparelho.';

  @override
  String get equalizerSettingsSubtitle =>
      'Bandas, presets e reforço de graves.';

  @override
  String get equalizerSheetSubtitle => 'Bandas, presets e reforço de graves';

  @override
  String get equalizerTitle => 'Equalizador';

  @override
  String get errorLogSub => 'Diagnóstico local (fica só no aparelho).';

  @override
  String get errorLogTitle => 'Log de erros';

  @override
  String get expandTooltip => 'Expandir';

  @override
  String get favorite => 'Favoritar';

  @override
  String get favoriteOffSub => 'Some da playlist Favoritas';

  @override
  String get favoriteOnSub => 'Entra na playlist Favoritas';

  @override
  String get foreverOption => 'Para sempre';

  @override
  String get groupAlbum => 'Álbum';

  @override
  String get groupArtist => 'Artista';

  @override
  String get groupFolder => 'Pasta';

  @override
  String get groupTracks => 'Faixas';

  @override
  String ignoredFoldersCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pastas fora da biblioteca.',
      one: '$count pasta fora da biblioteca.',
    );
    return '$_temp0';
  }

  @override
  String get ignoredFoldersEmptySub =>
      'Nenhuma. Áudios de WhatsApp/toques ficam misturados se o MediaStore marcar como música.';

  @override
  String get ignoredFoldersSheetSub =>
      'Faixas DENTRO da pasta somem da biblioteca. Cole o caminho da pasta (subpastas também contam).';

  @override
  String get ignoredFoldersTitle => 'Pastas ignoradas';

  @override
  String get invertSelection => 'Inverter seleção';

  @override
  String get languageEnglish => 'English';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Idioma';

  @override
  String get licensesSub => 'Bibliotecas usadas no app.';

  @override
  String get licensesTitle => 'Licenças de código aberto';

  @override
  String get minDurationAll => 'Todas as faixas aparecem (padrão).';

  @override
  String minDurationHide(String label) {
    return 'Esconde faixas com menos de $label — toques e notificações somem.';
  }

  @override
  String minDurationHideShort(String label) {
    return 'Esconde do catálogo o que tiver menos de $label — some com toques e notificações curtas.';
  }

  @override
  String get minDurationShowAll => 'Mostra todas as faixas (padrão).';

  @override
  String get minDurationTitle => 'Duração mínima';

  @override
  String minutesCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutos',
      one: '$count minuto',
    );
    return '$_temp0';
  }

  @override
  String get minutesHint => 'Ex.: 20';

  @override
  String get minutesLabel => 'Minutos';

  @override
  String minutesShort(int count) {
    return '$count min';
  }

  @override
  String get musicSearchHint => 'Buscar música, artista ou álbum';

  @override
  String get noErrorsRecorded => 'Nenhum erro registrado.';

  @override
  String get noIgnoredFolders => 'Nenhuma pasta ignorada';

  @override
  String get noTrackSelected => 'Nenhuma faixa selecionada';

  @override
  String get nowPlaying => 'Agora tocando';

  @override
  String get offOption => 'Desligado';

  @override
  String get openSettingsBtn => 'Abrir ajustes';

  @override
  String get pause => 'Pausar';

  @override
  String get pauseOnNoisySubtitle =>
      'Ao tirar o fone (com fio ou Bluetooth), a música pausa — sem retomada automática.';

  @override
  String get pauseOnNoisyTitle => 'Pausar ao desconectar fones';

  @override
  String get permissionAllow =>
      'Permita o acesso às músicas para ver sua biblioteca.';

  @override
  String get permissionBlocked =>
      'Permissão bloqueada. Libere nas Configurações do sistema para ver suas músicas.';

  @override
  String get permAllFiles => 'Todos os arquivos';

  @override
  String get permAllFilesSub =>
      'Listar PDFs no Android 13+ (acesso especial do sistema).';

  @override
  String get permMusic => 'Músicas';

  @override
  String get permNotifications => 'Notificações';

  @override
  String get permNotificationsSub =>
      'Notificação de música na tela de bloqueio (Android 13+).';

  @override
  String get permPhotos => 'Fotos';

  @override
  String get permVideos => 'Vídeos';

  @override
  String get play => 'Tocar';

  @override
  String get playGroupTooltip => 'Tocar grupo';

  @override
  String get playingNow => 'Tocando agora';

  @override
  String get previous => 'Anterior';

  @override
  String get queueAppend => 'Adicionar à fila';

  @override
  String get queueEmpty =>
      'Fila vazia — use \"Tocar a seguir\" ou \"Adicionar à fila\" no menu de uma música.';

  @override
  String queueHeader(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count faixas • toque para tocar, segure o alça para reordenar',
      one: '$count faixa • toque para tocar, segure o alça para reordenar',
    );
    return '$_temp0';
  }

  @override
  String get queuePlayNext => 'Tocar a seguir';

  @override
  String get queueTooltip => 'Fila de reprodução';

  @override
  String get recheckTooltip => 'Verificar novamente';

  @override
  String get removeFromListTooltip => 'Remover da lista';

  @override
  String get removeFromQueue => 'Remover da fila';

  @override
  String get repeat => 'Repetir';

  @override
  String get resumePlaybackSubtitle =>
      'Ao abrir o app, retoma a última música e posição.';

  @override
  String get resumePlaybackTitle => 'Continuar de onde parou';

  @override
  String get schedule => 'Agendar';

  @override
  String secondsShort(int count) {
    return '$count s';
  }

  @override
  String selectedCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selecionadas',
      one: '$count selecionada',
    );
    return '$_temp0';
  }

  @override
  String get settingsAbout => 'Sobre';

  @override
  String get settingsBackground => 'Segundo plano';

  @override
  String get settingsLibrary => 'Biblioteca';

  @override
  String get settingsPermissions => 'Permissões';

  @override
  String get settingsPlayback => 'Reprodução';

  @override
  String get settingsTrash => 'Lixeira';

  @override
  String get share => 'Compartilhar';

  @override
  String get shareApps => 'WhatsApp, Messenger e outros';

  @override
  String get shareSelected => 'Compartilhar selecionadas';

  @override
  String get shuffleTooltip => 'Embaralhar';

  @override
  String skippedKept(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count faixas embutidas no app foram mantidas.',
      one: '$count faixa embutida no app foi mantida.',
    );
    return '$_temp0';
  }

  @override
  String get sleepActiveUntilEnd => 'Dormindo ao fim da faixa';

  @override
  String sleepActiveIn(String time) {
    return 'Dormindo em $time';
  }

  @override
  String get sleepChipUntilEnd => 'Dormir ao fim da faixa';

  @override
  String sleepChipIn(String time) {
    return 'Dormir em $time';
  }

  @override
  String get sleepFadeNote => 'O áudio dá fade e para sozinho.';

  @override
  String get sleepTimerTooltip => 'Timer de sono';

  @override
  String speedTooltip(String speed) {
    return 'Velocidade ${speed}x';
  }

  @override
  String get sortAscendingOption => 'Ordem crescente';

  @override
  String get sortDescendingOption => 'Ordem decrescente';

  @override
  String get sortKeyAlbum => 'Álbum';

  @override
  String get sortKeyArtist => 'Artista';

  @override
  String get sortKeyDateAdded => 'Data de adição';

  @override
  String get sortKeyDuration => 'Duração';

  @override
  String get sortKeyMostPlayed => 'Mais tocadas';

  @override
  String get sortKeyTitle => 'Título';

  @override
  String get sortTooltip => 'Ordenar';

  @override
  String get themeDark => 'Escuro';

  @override
  String get themeLight => 'Claro';

  @override
  String get trackActionsTooltip => 'Ações da faixa';

  @override
  String trashExpiresIn(num days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'O que for excluído hoje será apagado em $days dias.',
      one: 'O que for excluído hoje será apagado em $days dia.',
    );
    return '$_temp0';
  }

  @override
  String get trashForeverSub =>
      'Nada é apagado sozinho; você esvazia manualmente.';

  @override
  String trashRetentionSubtitle(String label) {
    return 'Itens excluídos ficam na lixeira por $label.\nDepois disso são apagados sozinhos, sem aviso — o resto fica disponível em Arquivos → Mais opções → Lixeira.';
  }

  @override
  String get trashRetentionTitle => 'Prazo de exclusão';

  @override
  String tracksCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count faixas',
      one: '$count faixa',
    );
    return '$_temp0';
  }

  @override
  String get unfavorite => 'Desfavoritar';

  @override
  String get viewTrashSubtitle => 'Restaurar ou apagar definitivamente';

  @override
  String get viewTrashTitle => 'Ver lixeira';

  @override
  String daysCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dias',
      one: '$count dia',
    );
    return '$_temp0';
  }

  @override
  String get assetLockedMessage =>
      'Faixa embutida no app, não pode ser excluída.';

  @override
  String get optionSystem => 'Sistema';

  @override
  String addedUpNext(String title) {
    return 'A seguir: $title';
  }

  @override
  String addedInQueue(String title) {
    return 'Na fila: $title';
  }

  @override
  String get shareAssetSub => 'Faixa embutida no app: não é um arquivo';

  @override
  String get timerRangeError => 'Informe um número de 1 a 720.';

  @override
  String get cancelTimer => 'Desligar timer';

  @override
  String get next => 'Próxima';

  @override
  String get lyricsTooltip => 'Letras';

  @override
  String get amoledTitle => 'Tema escuro AMOLED';

  @override
  String get amoledSubtitle =>
      'Preto puro nos fundos do modo escuro — só tem efeito com o tema escuro ligado.';

  @override
  String get defaultSpeedTitle => 'Velocidade padrão';

  @override
  String get defaultSpeedSubtitle =>
      'Vale para toda a reprodução e volta no próximo boot.';

  @override
  String get sleepDefaultTitle => 'Timer de sono padrão';

  @override
  String get sleepDefaultSubtitle =>
      'Atalho no topo do menu do sono: agenda sem escolher de novo.';

  @override
  String get sleepDefaultLabel => 'Padrão do timer';

  @override
  String get stopPausedTitle => 'Parar serviço após pausar';

  @override
  String get stopPausedSubtitle =>
      'Encerra o player depois de N minutos pausado (0 = nunca).';

  @override
  String get defaultSortTitle => 'Ordenação padrão';

  @override
  String get defaultSortSubtitle =>
      'Como a lista de músicas é ordenada ao abrir o app.';

  @override
  String get seekLabel => 'Posição da música';

  @override
  String get emptyPlaylists => 'Nenhuma playlist ainda.';

  @override
  String get newPlaylistBtn => 'Nova playlist';

  @override
  String get rescanBtn => 'Atualizar';
}
