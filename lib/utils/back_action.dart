/// O que o botão "voltar" deve fazer, conforme o estado atual.
///
/// Extraído do widget para ser testável sem app: a decisão é pura (entrada ->
/// saída) e o widget só executa o efeito.
enum BackAction {
  /// Não faz nada além de avisar (primeiro toque na raiz).
  warnThenExit,

  /// Encerra o app (segundo toque em sequência).
  exit,

  /// Volta para a primeira aba.
  goToFirstTab,

  /// Sem ação: algo acima (diálogo, folha, tela empilhada) já consumiu o
  /// gesto e este código nem é chamado.
  none,
}

/// Resultado de interpretar um toque do botão voltar na raiz do app.
class BackDecision {
  final BackAction action;

  /// Instante do toque, para a janela de confirmação.
  final DateTime now;

  const BackDecision(this.action, this.now);

  /// Momento do toque anterior, ou null se não houver.
  ///
  /// A UI guarda esse valor para a próxima decisão.
  DateTime? get nextLastPress =>
      action == BackAction.exit || action == BackAction.goToFirstTab
      ? null
      : now;
}

/// Interpreta um toque do botão voltar na raiz.
///
/// Ordem do que é reversível, do mais " interno" ao mais externo:
///  1. diálogo/folha/tela empilhada já consumiram o gesto — o SO não chega
///     aqui (ver [BackAction.none]);
///  2. se não está na primeira aba, volta para ela: perder a aba por um toque
///     acidental é pior do que um toque "a menos" ficar;
///  3. na primeira aba, o primeiro toque só avisa; sair exige um segundo toque
///     dentro de [exitWindow].
///
/// Encerrar o app é sempre a ÚLTIMA opção, deliberadamente: é a única ação
/// irreversível.
BackDecision resolveBack({
  required int currentTabIndex,
  required DateTime now,
  DateTime? lastPress,
}) {
  if (currentTabIndex != 0) {
    return BackDecision(BackAction.goToFirstTab, now);
  }
  final DateTime? previous = lastPress;
  if (previous != null && now.difference(previous) < exitWindow) {
    return BackDecision(BackAction.exit, now);
  }
  return BackDecision(BackAction.warnThenExit, now);
}

/// Janela dentro da qual o segundo toque encerra o app.
const Duration exitWindow = Duration(seconds: 2);
