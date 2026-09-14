# Correções do Audify — Auditoria de estabilidade (ago/2026)

Este documento explica, em linguagem simples, **o que estava quebrado**, **por quê**
e **o que foi mudado**. Foi feito para o dono do projeto acompanhar as correções
sem precisar ler código.

---

## Resumo rápido

| # | Problema | Causa raiz | Correção |
|---|----------|-----------|----------|
| 1 | App trava no release e "não abre mais" | Regras de minificação (R8) incompletas + nenhum tratamento de erro global | Regras ProGuard completas para todos os plugins + captura global de erros com log local |
| 2 | Música para / notificação some em segundo plano | Serviço de áudio saía do modo foreground ao pausar; fabricantes matavam o app | Serviço agora permanece em foreground mesmo pausado + pedido de isenção de otimização de bateria |
| 3 | Sem diagnóstico quando o app fecha sozinho | Nenhum erro era registrado | Log local `crash_log.txt` visível em Configurações → Log de erros |
| 4 | App não reagia ao ir/voltar do segundo plano | Nenhum observador de ciclo de vida | MainScreen e player de vídeo agora observam pausa/retorno |
| 5 | Riscos adicionais encontrados na auditoria | Race no banco, cache sem limite, leaks, catches vazios | Detalhados na seção 5 |

---

## 1. O crash silencioso no release (suspeita principal confirmada)

### O que estava quebrado
O APK de release é "minificado": o Android remove e renomeia classes que ele
acredita não serem usadas. O arquivo de regras (`proguard-rules.pro`) só protegia
2 bibliotecas (audio_service e on_audio_query). Todas as outras ficavam sujeitas à
remoção/renomeação — incluindo:

- **video_player** (ExoPlayer/Media3 por baixo)
- **syncfusion_flutter_pdfviewer** (módulo nativo do leitor de PDFs)
- **file_picker**, **share_plus**, **open_filex**, **permission_handler**
- **sqflite** (banco de dados), **audioplayers**, **path_provider**, etc.

Quando um desses plugins resolve uma classe/recurso **por nome em tempo de
execução** e o minificador renomeou essa classe, o app explode **sem nenhuma
mensagem** — exatamente o sintoma relatado: funciona no debug, trava no release.
E como alguns desses canais são usados logo na abertura, um estado corrompido
pós-crash deixava o app **crashando em loop** até limpar dados/reinstalar.

### O que foi feito
- `android/app/proguard-rules.pro` foi reescrito com regras explícitas para
  **todos** os plugins do projeto (nomes verificados um a um nos pacotes
  instalados), além de Media3/ExoPlayer, FileProvider e anotações.
- Estratégia deliberada de "proteger demais": como o uso é pessoal via sideload,
  alguns KB a mais no APK valem a estabilidade.
- Observações honestas:
  - `image`, `exif`, `archive` e `crypto` são pacotes **100% Dart** — nunca foram
    afetados pelo minificador nativo (não precisam de regra; ficou documentado
    para não haver falso mistério).
  - A Syncfusion não publica regras oficiais de R8 para o visualizador Flutter
    (o renderizador é Dart); o módulo nativo do plugin foi protegido por nome.

---

## 2. Reprodução em segundo plano

### O que estava quebrado
1. Na configuração do audio_service, `androidStopForegroundOnPause: true`
   derrubava o serviço de primeiro plano **toda vez que a música pausava**. Em
   aparelhos Xiaomi/MIUI, Samsung e Motorola, o Android aproveitava isso para
   matar o processo minutos depois — perdendo notificação, controles da tela de
   bloqueio e posição.
   - Detalhe técnico descoberto: o próprio package **rejeita** a combinação
     `androidNotificationOngoing: true` com `stopForegroundOnPause: false`
     (existe um assert no código dele). A combinação correta escolhida foi
     `ongoing: false` + `stopForegroundOnPause: false`. Efeito colateral bom:
     deslizar a notificação para fora agora **para a música de forma limpa**
     (antes disso não havia caminho de encerramento limpo).
2. O comentário no AndroidManifest dizia que o segundo plano dependia só de
   WAKE_LOCK "sem depender do foreground service" — informação falsa/desatualizada
   que já causou decisões erradas. Reescrito.
3. Interrupções de áudio tratavam tudo igual: qualquer fim de interrupção retomava
   a música — inclusive quando **outro app assumiu o áudio permanentemente**.
   Agora: ligação/notificação → pausa e **retoma sozinha**; outro app assumiu →
   pausa e **fica pausada** (comportamento recomendado pela documentação).
4. Faltava pedir ao usuário a **isenção de otimização de bateria** — principal
   motivo de players morrerem em segundo plano em MIUI/Samsung/Motorola mesmo
   com foreground service correto.

### O que foi feito
- Config corrigida em `lib/main.dart` (serviço permanece vivo pausado).
- Manifest atualizado (comentários corretos + permissão
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`).
- Novo item em **Configurações → Segundo plano**: "Ignorar otimização de bateria",
  que abre o diálogo oficial do sistema.
- `lib/services/audio_service.dart` reescrito por partes: interrupções
  diferenciadas, todos os pontos de chamada ao player protegidos (inclusive os
  que rodam dentro de callbacks de stream), erros dos botões da notificação
  capturados (um throw ali atravessa o canal nativo).

---

## 3. Diagnóstico de crashes (log local, 100% offline)

### O que estava quebrado
Qualquer exceção não tratada derrubava o app inteiro **sem deixar rastro**. Se o
app fechasse sozinho, era impossível saber o porquê depois.

### O que foi feito
- Novo `lib/services/error_log_service.dart`: registra erros de três fontes —
  erros do framework Flutter (`FlutterError.onError`), exceções assíncronas do
  sistema (`PlatformDispatcher.instance.onError`) e tudo que escapar da zona
  principal (`runZonedGuarded`).
- Os logs vão para `logs/crash_log.txt` dentro dos documentos do app, com teto
  de ~128 KB (nunca enche o armazenamento). **Nada sai do aparelho** — zero
  telemetria/analytics, como o projeto exige.
- Para consultar: **Configurações → Log de erros** (com botão de limpar).
- Bônus direto contra o sintoma "não abre mais": se a inicialização do
  audio_service falhar (estado ruim pós-crash), o app **agora abre mesmo assim**
  em modo degradado (som sem notificação) em vez de crashar em loop.

---

## 4. Ciclo de vida (ir para segundo plano / voltar)

### O que estava quebrado
Nenhuma tela observava o ciclo de vida: o app não salvava a sessão ao sair, não
ressincronizava a UI ao voltar (a posição mostrada podia estar defasada em relação
ao que você controlou pela notificação/tela de bloqueio) e o **vídeo continuava
tocando som com o app minimizado**.

### O que foi feito
- `MainScreen` agora observa `paused/resumed/detached`: ao ir para segundo plano
  salva "continuar de onde parou" imediatamente; ao voltar, ressincroniza
  posição/status/erros com o serviço real de áudio.
- Player de vídeo pausa sozinho ao sair do app (e não retoma sozinho — padrão dos
  players). Também protegi o caso de troca rápida de vídeo onde o controller
  morre entre o seek e o play.

---

## 5. Outros problemas encontrados na auditoria completa

Estes não estavam na lista original, mas foram encontrados e corrigidos:

1. **Race condition no banco SQLite** (`playlist_database.dart`): duas operações
   simultâneas no boot podiam abrir o banco **duas vezes** (vazando uma conexão
   e arriscando escritas concorrentes em handles diferentes). Agora há um lock
   de abertura (Completer): uma única conexão, todos aguardam a mesma.
2. **Cache de miniaturas era write-only** (`ThumbnailDiskCache`): as miniaturas
   eram gravadas em disco mas **nunca relidas** — puro desperdício de espaço.
   Agora lê do disco antes de regerar. Além disso:
   - Ganhou **limite de tamanho total (~48 MB)** além do limite de arquivos;
     a poda roda em isolate (não trava a UI).
   - **Bug grave relacionado:** PDFs usavam `path.hashCode` como chave — o
     hashCode do Dart muda a cada abertura do app, então as chaves nunca
     batiam e arquivos órfãos **se acumulavam para sempre** no disco. Trocado
     por SHA-1 estável do caminho.
3. **Leak no visualizador de PDF**: o `PdfViewerController` nunca era descartado.
   Agora é. Também tirei I/O síncrona de dentro do `build()`.
4. **Catches vazios/silenciosos**: ~15 pontos que engoliam erros sem registro
   foram atualizados para registrar o erro (logcat/log local) ou dar feedback
   na tela — exemplos: falha ao carregar músicas/vídeos/galeria/PDFs, salvar
   sessão, restaurar da lixeira, compartilhar arquivos, gerar cópia sem EXIF,
   favoritos de PDF. Os guards internos dos jobs em isolate (que pulam arquivos
   individuais ilegíveis de propósito, milhares de vezes por varredura)
   permanecem silenciosos **por design** — registrá-los geraria spam inútil.
5. **Favoritos de PDF** podiam chamar `notifyListeners()` após o dispose (crash
   em debug) — recebeu o mesmo guard `_isDisposed` dos outros providers.
6. **Defesa no boot**: preferências e audio_service agora são inicializados
   dentro de try/catch — nada do boot pode mais impedir o app de abrir.

---

## Como validar (APK de release)

```bash
flutter analyze        # 0 issues
flutter test           # 66 testes passando
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

> Importante: instale sempre o **--release** no aparelho. O bug original só
> existia no release — validar no debug não prova nada.

---

## Checklist de teste manual (aparelho físico)

Marque cada item. Se algo falhar, abra **Configurações → Log de erros** antes de
reportar — a causa provavelmente estará lá.

### A. Segundo plano (o problema principal)
- [ ] A1. Tocar música → botão Home → esperar **10 min** com tela apagada →
      a música continua? A notificação responde a play/pause/próxima?
- [ ] A2. Com a tela bloqueada, controlar a reprodução pela **tela de bloqueio**
      (play/pause/next/prev/arrastar a barra).
- [ ] A3. Pausar a música → Home → esperar 5 min com tela apagada → voltar →
      tocar play na notificação: retoma da posição certa?
- [ ] A4. Receber uma **ligação** (ou simular) durante a reprodução: pausa sozinha
      e **retoma** após desligar?
- [ ] A5. Abrir **YouTube/outro player**, dar play: a música do Audify para e
      **não volta sozinha** (perda permanente de foco)?
- [ ] A6. Ir em **Configurações → Segundo plano** e conceder "Ignorar otimização
      de bateria" (deve aparecer ✓ verde). Refazer A1 num Xiaomi/Samsung/Moto,
      se possível.

### B. Fechamento e reabertura (o sintoma "não abre mais")
- [ ] B1. Com música tocando, **deslizar o app fora dos recentes**: deve parar de
      tocar de forma limpa (ou continuar tocando com notificação — ambos ok),
      **sem crash**.
- [ ] B2. Deslizar a **notificação** para fora durante a reprodução: música para
      de forma limpa, sem crash.
- [ ] B3. Reabrir o app imediatamente depois de B1/B2: abre normal, lista carrega,
      dá para tocar de novo.
- [ ] B4. Forçar parada (Configurações do sistema → Aplicativos → Audify → Forçar
      parada) e reabrir: abre normal.

### C. Estresse do player
- [ ] C1. Trocar de música **rapidamente 20x seguidas** (tocar outra faixa a cada
      ~1s): sem travar, sem áudio duplo/sobreposto, sem crash.
- [ ] C2. Deixar uma playlist tocar até o fim natural: avança sozinha conforme o
      modo repeat; repeat-one repete a mesma.
- [ ] C3. Arrastar a barra de progresso várias vezes seguidas durante a
      reprodução.

### D. Estabilidade geral (15–20 min alternando abas)
- [ ] D1. Alternar entre **Música, Vídeos, Galeria, Arquivos, PDFs, Playlists e
      Configurações** várias vezes,abrindo itens de cada tipo (vídeo, foto, PDF,
      pasta, APK).
- [ ] D2. Abrir um vídeo → apertar Home durante a reprodução → voltar: o vídeo
      **pausou** ao sair e não retomou sozinho.
- [ ] D3. Galeria com muitas fotos: rolar bastante (paginação), entrar num álbum e
      voltar. Sem travamentos crescentes (cache de miniaturas limitado).
- [ ] D4. Abrir o **mesmo PDF** duas vezes: segunda abertura é instantânea
      (miniatura/capa vinda do disco) e retoma da última página lida.
- [ ] D5. Criar playlist, adicionar/remover músicas, reordenar arrastando, excluir
      a playlist — sem erros e sobrevive a fechar/abrir o app.
- [ ] D6. Excluir um arquivo/música que está numa playlist → a playlist não pode
      ficar com item morto.

### E. Crash forçado (testa diretamente o "não abre mais")
- [ ] E1. Se conseguir reproduzir QUALQUER crash: reabra o app. Ele **deve abrir
      normalmente** (boot blindado) e o erro deve aparecer em
      **Configurações → Log de erros**.
- [ ] E2. Verificar que o log de erros tem botão "Limpar" funcionando e que o
      arquivo fica pequeno (teto de 128 KB).

### F. Privacidade
- [ ] F1. Confirmar em Configurações do Android → Dados móveis/Wi-Fi que o Audify
      não usa rede (modo avião: todas as funções continuam funcionando).
