# Varredura visual (QA) — 2026-10-17

Base: `dev/parallel` 8415d6e (inclui Query Builder). Capturas com `--window-size 1037x695`, `-appearance light|dark`,
`BUNNYGRID_DATA_DIR` em scratch e servidores descartáveis (PostgreSQL 17, MySQL, MongoDB, Redis).
As capturas ficam fora do git, em `<scratchpad>/visual-qa/shots/` (`NOME-light.png` / `NOME-dark.png`; `after*` = depois das correções;
diálogos com `-0`/`-1` = folha e janela principal).

Status: **ok** (sem regressão), **fixed** (corrigido nesta rodada), **pending** (anotado; depende de lógica de outro agente ou fica para depois).

## Janela principal e navegação

| Tela | Referência | Captura | Status | Notas |
|---|---|---|---|---|
| Janela / Objects (SQLite) | objects-tables.png, main-db.png | main-*, objects-* | fixed | O painel direito abria com 345 pt (Navicat ≈ 297); agora 300 pt, o que devolve espaço ao centro. Lista Objects, toolbar e status bar ok. |
| Árvore PostgreSQL | — | pg-main-*, pg-table-* | fixed | A pasta **GridFS** (só MongoDB) aparecia em todo schema PostgreSQL (`ObjectCategory.categories` usava `allCases`). |
| Menu de contexto da conexão | context-connection.png | connmenu-*, after-connmenu-* | fixed | "Share…" era o único item com ícone (ShareLink); agora só texto. Pendente: as amostras de cor são maiores que as do Navicat (estilo palette do sistema). |
| Menu da conta / AI | — | accountmenu-*, askai-* | ok | |

## Tabela, grade e editor

| Tela | Referência | Captura | Status | Notas |
|---|---|---|---|---|
| Visualizador de tabela | table-view.png | table-*, after-table-* | fixed | NULL aparecia como "(Null)"; o Navicat 17 mostra "(NULL)" (grade, Data Generation, Import, form view, editor de célula). |
| Edições pendentes | — | demoedits-*, after-demoedits-* | fixed | "4 pending changes" quebrava em duas linhas ("4 / pendi…") no rodapé. |
| Editor de consulta | query-new.png, query-result.png | query-*, after2-query-* | fixed | Conteúdo mais largo que o painel: editor/grade deslocados ~34 pt para a direita e Run/Stop/Explain cortados. Os seletores de conexão/banco agora encolhem (mín. 96 pt). "Load More" / "Fetch All" quebravam em duas linhas. Cores do realce (palavras‑chave azuis em negrito, strings rosa, comentários cinza) conferem com a referência. |
| Explain | query-result-info.png | explain-* | ok | |
| Painel AI | ai-chat-empty.png | aipane-* | pending | O ícone da aba selecionada não fica azul como o "AI" do Navicat (o ícone do provedor é colorido). A terceira sugestão fica sob a caixa de texto (rola). |
| Cell editor / Value editor | — | celleditor-*, valueeditor-* | ok | |
| Query Builder | — | qb-* | fixed / pending | Rodapé "2 table(s), 1 join(s)" → "2 tables, 1 join". As cláusulas ficavam num ScrollView horizontal e nunca quebravam: agora rolam só na vertical, as fichas quebram linha e uma ficha longa (JOIN) é truncada no meio com tooltip. A prévia SQL quebra linha em vez de cortar. Pendente: a linha de condição do WHERE (HStack de seletores) ainda não quebra em painéis estreitos. |

## Design / Model / BI / Automation

| Tela | Referência | Captura | Status | Notas |
|---|---|---|---|---|
| Design Table — Fields | table-design.png | design-*, after-design-*, my-design-* | fixed | Name/Type com 180/140 pt empurravam Not Null e Key para fora; agora 100/100 como no Navicat, Key 40 pt e tipo em fonte normal (não monoespaçada). Pendente: o painel direito mostra a conexão em vez da tabela (seleção do navegador — lógica). |
| Design — Indexes/FK/Uniques/Triggers/Options/SQL Preview | design-*.png | design-<aba>-* | ok | |
| New Table | — | newtable-* | ok | |
| Model (ER) | model-untitled.png | model-* | ok | Canvas é de outro agente; nada a corrigir no estilo. |
| BI | — | bi-*, after2-bi-* | fixed / pending | minWidth de 420 pt no centro + barra lateral transbordavam o painel (cortado dos dois lados). Reduzido (centro 260, lateral 170, campo do nome flexível). Pendente: com o painel direito aberto, o cartão KPI ainda corta à direita em 1037 pt. |
| Automation | — | automation-*, after-automation-* | fixed | O texto do estado vazio "No Batch Job" saía cortado à direita (minWidth 360 + lista 180). |

## Diálogos e assistentes

| Tela | Referência | Captura | Status | Notas |
|---|---|---|---|---|
| Data Transfer | — | datatransfer-*, after-datatransfer-* | fixed | "Target" ficava abaixo do seletor Connection / SQL File, desalinhado de "Source"; o seletor foi para a linha do título (pequeno). |
| Structure Sync | — | structuresync-* | ok | Pendente (texto de log): "table(s)", "record(s)", "difference(s)" nos logs de sync. |
| Backup / Export / Import / Data Generation | — | backup-*, export-*, import-*, generate-* | pending | Cabeçalhos inconsistentes entre folhas (com e sem divisor, cores de ícone teal/magenta/cinza). Data Generation: prévia mistura nomes e e-mails de pessoas diferentes (lógica do gerador). |
| New Connection | newconn-dialog.png | newconn-* | ok | Linhas um pouco mais altas que no Navicat (25 vs 22 pt). |
| Edit Connection (PG, SSL) | editconn-sqlite.png | pg-editconn-* | ok | |
| Options — General/Tabs/Editor/Records/Advanced | options-*.png | settings-<aba>-* | pending | Falta a aba **Environment** do Navicat. |
| Options — AI | options-ai-assistant-form.png | settings-ai-*, after2-settings-ai-* | fixed | O formulário do Claude era mais alto que os 350 pt reservados e invadia "AI Assistant" e "AI Assistant UI". A nota sobre Effort virou tooltip e o API Endpoint fica numa linha (truncado no meio). |

## Outros bancos

| Tela | Referência | Captura | Status | Notas |
|---|---|---|---|---|
| PostgreSQL tabela | table-view.png | pg-table-* | ok | (GridFS corrigido acima.) |
| MySQL tabela / design | — | my-table-*, my-design-* | ok | |
| MongoDB grid / tree / shell | — | mongo-grid-*, mongo-tree-*, mongo-shell-* | fixed | "Documents 1–50 of 50" quebrava em duas linhas no rodapé da coleção. |
| Redis chave / console / server monitor | — | redis-key-*, redis-console-*, redis-server-* | pending | O resumo da chave aparece duas vezes (rodapé da aba e status bar). Placeholder do filtro SCAN cortado. |

## Rodada 2 (pendências resolvidas; base dev/parallel 1a3e169)

Capturas `r2-*`, `r3-*`, `r4-*`, `r5-*` (claro e escuro).

| Item | Captura | Status | Notas |
|---|---|---|---|
| Split view / BI | r2-bi-*, r3-bi-* | fixed | O host do workspace passa a usar `sizingOptions = [.minSize]`: um tab que precisa de mais largura estreita os painéis laterais (até o mínimo deles) em vez de transbordar. Padrões 240 / flexível / 300 e a animação nativa de recolher mantidos. O dashboard do BI, abaixo do mínimo de 480 pt da grade, rola na horizontal em vez de cortar o cartão KPI. |
| Query Builder — WHERE | r2-qb-* | fixed | Cada condição (campo, operador, valores, botões) usa o mesmo layout de fluxo das fichas e quebra linha em painéis estreitos. |
| Design Table — painel direito | r2-design-*, r5-design-options-* | fixed | O painel Info mostra o cartão da tabela em edição (Root Page, Has Indexes…), como no Navicat, qualquer que seja a seleção do navegador. Options: "AUTOINCREMENT" não quebra mais em duas linhas. |
| Data Generation | r2-generate-* | fixed | Cada linha sorteia uma pessoa: First Name, Last Name, Full Name e Email da mesma linha batem (ex.: "Samuel Almeida" / samuel.almeida1@…). Teste novo em `GeneratorIndexTests`. |
| Fonte da grade | r2-table-*, r2-pg-table-* | fixed | 12 pt (era 13), altura da linha mantida em 22 pt como na referência. |
| Formato de números | r2-table-*, r4-result-edits-* | fixed | Um só formatador (`countText`, `Components/CountText.swift`): inteiro sem separador, como o Navicat ("Record 1 of 1000", "1000 records", "Rows 1200", "First 1000 rows"). Datas, durações e porcentagens continuam no formato do locale. |
| Aba AI do painel direito | r2-aipane-* | fixed | Marca "AI" monocromática como as outras abas, azul quando selecionada (o logo colorido do provedor não mudava de cor). |
| Cabeçalhos das folhas | r2-backup-*, r2-export-*, r2-import-*, r2-generate-*, r2-datatransfer-*, r2-structuresync-* | fixed | `SheetHeader` compartilhado: símbolo teal, título em headline, linha de local em caption e divisor logo abaixo. |
| Plurais "(s)" | — | fixed | Logs do Sync/Data Transfer, diálogos de exclusão (Redis, MongoDB), BI ("1 group"), Structure Sync, chave estrangeira e mensagens do console Redis. Helper `countLabel`. |
| Redis | r2-redis-key-* | fixed | O resumo da chave fica só na status bar; o rodapé da aba aparece apenas com erro ou Load More. Placeholder "Key pattern" (o exemplo foi para o tooltip). |
| New Connection | r2-newconn-*, r4-newconn-* | fixed | Linhas dos filtros com 22 pt, como no Navicat. |
| Amostras de cor no menu da conexão | r6-connmenu-* | fixed (rodada 3) | A linha "Color:" agora é uma view AppKit própria (`ColorSwatchMenuItem`): nove amostras de 10 pt numa linha, como no Navicat, com o anel na cor atual e destaque ao passar o mouse. O cabeçalho "Color:" continua. |
| Edit Connection (todas as abas) | r6-ec-sqlite-*, r6-ec-pg-*, r6-ec-mongo-*, r6-ec-redis-* | fixed (rodada 3) | A área principal tem largura fixa (900 − barra de perfis) e recorta o que passar: nenhuma aba empurra mais a folha para a esquerda. "Connection Profiles" e "Main Profile" voltaram ao recuo certo. Conferido em General/Advanced/Databases/Remarks (SQLite), General/Advanced/Databases/SSL/SSH/Remarks (PostgreSQL), MongoDB e Redis. |
| Novas telas (1a3e169) | r4-result-edits-*, r4-result-form-*, r4-result-profiling-*, r4-design-uniques-*, r4-editconn-db-* | ok | Edição no resultado, Form View, Data Profiling e Uniques ok (Edit Connection: ver abaixo). |
| Settings › Environment | — | — | Fica de fora (não se aplica ao BunnyGrid). |

## Modos Simple / Advanced (2026-10-17)

Capturas fora do git, em `<scratchpad>/modes/cap/zz-cap-*/shots/` (claro e escuro, pela cópia do harness com bundle id próprio, sem tocar nas preferências do app de verdade). A tela estava bloqueada: o harness agora trata as janelas visíveis como não ocultas (`virtualizeOcclusion`), senão o SwiftUI não expõe a árvore de acessibilidade.

| Tela | Captura | Status | Notas |
|---|---|---|---|
| Boas-vindas (primeira execução) | zz-cap-onb-*-onboarding-sheet, -onboarding-simple-sheet | fixed | Ícone, dois cartões com prévia da janela (ícones da própria toolbar, não captura), Advanced marcado e "Default", aparência em segmentos aplicada na hora, Continue com Return. As frases dos cartões eram cortadas ("sync…"): agora até duas linhas, cartões da mesma altura. |
| Janela principal Simple / Advanced | zz-cap-main-*-simple-table, -advanced-table | ok | Simple: Connection, New Query, Table, View, Query, View, avatar, mesmo espaçamento; barra da tabela sem Table Profile, Begin Transaction, Data Profiling, Data Generation, Data Masking e BI. |
| Avatar → Theme | zz-cap-main-*-account-popover, -theme-menu-menu | ok | Linha "Theme" com o valor atual ("Dark · Simple"); menu com seções Appearance e Interface e marcas nativas. |
| Settings › General (Simple) | zz-cap-main-*-settings-general | ok | Só General, Editor, Records e AI; linha Interface em segmentos com explicação. |
| New Connection (Simple) | zz-cap-main-*-newconn-sheet | ok | Só os sete motores suportados; sem Vendor Filter nem serviços de nuvem. |
| Aba do Advanced no Simple | interface-mode-shortcuts-advanced-tab-in-simple | ok | Selo "Advanced" discreto ao lado do título. |
