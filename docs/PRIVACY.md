# Privacidade — Audify

Resumo em uma frase: **o Audify não coleta, não transmite e não vende dados.**
Todo processamento acontece no aparelho.

## O que o app NÃO faz

- Não tem conta, login, nuvem ou sincronização.
- Não usa analytics, crash reporting remoto, anúncios ou telemetria.
- Não acessa a internet no release (a permissão `INTERNET` é removida do
  manifesto de release).
- Não envia nomes de arquivos, histórico, playlists ou logs para lugar nenhum.

## O que fica no aparelho

| Dado | Onde | Para quê | Como apagar |
|---|---|---|---|
| Playlists e favoritos | banco SQLite local | organizar mídia | excluir playlist / limpar dados do app |
| Histórico e “continuar de onde parou” | armazenamento interno | retomar a sessão | Configurações do app / limpar dados |
| Lixeira do app | pasta `trash/` interna | desfazer exclusão | esvaziar lixeira / limpar dados |
| Log de erros | `logs/` interno, teto de 128 KB | diagnóstico local | Configurações → Log de erros → Limpar |
| Cache de capas/notificação | cache interno | desempenho | limpar cache / limpar dados |
| Preferências | SharedPreferences | tema, idioma, ordenação | limpar dados |

Nada disso é copiado para backup do Android: `allowBackup=false` e regras de
exclusão (`backup_rules.xml`, `data_extraction_rules.xml`) cobrem logs,
lixeira, banco, prefs e armazenamento externo.

## Permissões e por quê

| Permissão | Finalidade |
|---|---|
| `READ_MEDIA_AUDIO/IMAGES/VIDEO` (13+) | listar e tocar mídia do usuário |
| `READ_MEDIA_VISUAL_USER_SELECTED` (14+) | acesso parcial a fotos/vídeos escolhidos |
| `READ/WRITE_EXTERNAL_STORAGE` (≤12) | ler/gerenciar arquivos em versões antigas |
| `MANAGE_EXTERNAL_STORAGE` (11+) | gerenciar arquivos fora do MediaStore (lixeira, renomear, ZIP, PDFs) |
| `POST_NOTIFICATIONS` (13+) | controle de reprodução na notificação |
| `FOREGROUND_SERVICE(_MEDIA_PLAYBACK)` | continuar tocando em segundo plano |
| `WAKE_LOCK` | evitar corte de áudio com tela apagada |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | opcional, pedido pelo usuário para fabricantes agressivos |
| `REQUEST_INSTALL_PACKAGES` | instalar APK escolhido pelo usuário (gerenciador de APK) |

O app não pede `INTERNET`, `CAMERA`, `MICROFONE`, localização ou contatos.

## Compartilhamento

Quando o usuário escolhe “compartilhar” ou “editar”, o app entrega uma URI
temporária via `FileProvider` ao app escolhido. A partir daí, o tratamento é
do app de destino e da política dele.

## Crianças

O app não é direcionado a crianças e não coleta dados de ninguém.

## Direitos do titular (LGPD/GDPR)

Como não há coleta remota, os dados ficam sob controle do usuário no aparelho.
Para apagar tudo: Configurações do Android → Apps → Audify → Armazenamento →
Limpar dados (ou desinstalar). Arquivos de mídia do usuário não são apagados
por “limpar dados”; eles pertencem ao usuário e só saem por ação explícita
de exclusão.

## Dependências de terceiros

O app usa bibliotecas open source (Flutter, just_audio, audio_service,
video_player, sqflite, file_picker, permission_handler etc.) e o
`syncfusion_flutter_pdfviewer` para PDF. O Syncfusion exige licença para uso
comercial; a licença do projeto e a do Syncfusion estão **pendentes de
decisão do dono** (`PENDENTE.md`). Nenhuma dessas bibliotecas recebe dados
porque o release não tem rede.

## Contato

Não há canal público definido. O dono do projeto deve definir um contato de
privacidade antes de publicar em loja.
