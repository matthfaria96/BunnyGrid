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

## Pendências estruturais (outros agentes)

- **Split view**: `MainSplitView` usa `sizingOptions = []`, então o conteúdo SwiftUI com largura mínima maior que o painel transborda centralizado (cortado dos dois lados) em vez de empurrar o painel direito. Reduzi os minWidth que causavam isso, mas o ideal é o split respeitar o mínimo do conteúdo.
- Grade: a fonte das células parece ~1 pt maior que a do Navicat (13 vs 12).
- Contagens com separador de milhar do locale ("1.000 records", "Rows 1.200") e sem ele ("Record 1 of 1000") lado a lado.
