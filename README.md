# BunnyGrid

Cliente de bancos de dados nativo para macOS, em Swift e SwiftUI.
Conecta em **SQLite, PostgreSQL, MySQL e MariaDB**. Mostra a árvore de objetos, abre tabelas num grid paginado e executa SQL num editor com realce de sintaxe.

Referências:
- **Beekeeper Studio**: arquitetura (contrato de driver, fluxo conexão → árvore → abas). Usado só como referência; nenhum código foi copiado (veja [Licenças](#licenças)).
- **Navicat Premium**: mapa de funções em `../Clones/Navicat Premium/SPEC.md` (só metadados públicos do bundle). Define o roadmap em [docs/ROADMAP.md](docs/ROADMAP.md).

## Requisitos

- macOS 14 ou posterior
- Xcode 16 ou posterior (o projeto foi feito com Xcode 27 e Swift 6.4)

Se `xcode-select -p` aponta para as Command Line Tools, use o Xcode só nesta sessão:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Compilar e rodar

```sh
swift build                    # compila
swift test                     # testes do núcleo (Swift Testing)
scripts/bundle.sh              # gera build/BunnyGrid.app (release); "debug" para depurar
open build/BunnyGrid.app
```

Também dá para abrir o pacote no Xcode (`open Package.swift`) e rodar o esquema `BunnyGrid`.

### Opções de desenvolvimento

```sh
# Isola as conexões salvas numa pasta temporária, abre o banco de exemplo e já abre uma tabela e uma consulta
BUNNYGRID_DATA_DIR=/tmp/bg build/BunnyGrid.app/Contents/MacOS/BunnyGrid \
  Resources/Samples/demo.sqlite --open-table customers --query "SELECT * FROM orders LIMIT 10"
```

No build de debug: `--demo-edits` (com `--open-table`) cria alterações pendentes de exemplo, `--focus-cell` foca uma célula, `--show-objects` abre a aba Objects com a pasta Tables selecionada, `--design TABELA` abre o Design Table (com `--design-section "Foreign Keys"` ou outra aba já selecionada e `--demo-fk` para uma chave alterada pendente), `--new-table` abre o New Table, `--connect-first` abre a primeira conexão salva, `--begin-transaction` e `--generate` (com `--open-table`) abrem o modo de transação e a Data Generation.

### Testes de integração com PostgreSQL

Com um PostgreSQL acessível (ex.: `brew install postgresql@17 && brew services start postgresql@17`):

```sh
BUNNYGRID_PG_PORT=5432 BUNNYGRID_PG_USER=$USER BUNNYGRID_PG_PASSWORD= BUNNYGRID_PG_DATABASE=postgres swift test
```

Sem `BUNNYGRID_PG_PORT` esses testes são pulados. Cada teste cria e apaga um schema próprio.

## Estrutura

```
Sources/
  BunnyGridCore/          núcleo sem UI (testável)
    Models/               ConnectionConfig, objetos, colunas, CellValue, QueryResult
    Drivers/              protocolo DatabaseDriver + SQLite (libsqlite3), PostgreSQL (PostgresNIO), MySQL/MariaDB (MySQLNIO)
    SQL/                  SQLDialect (aspas, SELECT paginado) e SQLSplitter (divide scripts em comandos)
    Storage/              ConnectionStore (JSON em Application Support) e KeychainStore (senhas)
  BunnyGrid/              app SwiftUI
    App/                  BunnyGridApp, AppModel (conexões e sessões), Session (árvore e abas)
    Views/                janela, barra lateral, editor de conexão, abas de tabela e de consulta
    Components/           ResultGridView (NSTableView) e SQLEditorView (NSTextView)
Tests/BunnyGridCoreTests  splitter, dialeto e driver SQLite
Resources/Samples         demo.sqlite para testes manuais
Resources/AppIcon.icon    ícone do app no formato do Icon Composer (camadas Liquid Glass)
scripts/icon              arte original e scripts que geram as camadas do ícone
```

Dados do usuário:
- conexões: `~/Library/Application Support/BunnyGrid/connections.json`
- histórico: `~/Library/Application Support/BunnyGrid/history.json`
- consultas salvas e favoritos: `~/Library/Application Support/BunnyGrid/queries.json` e `favorites.json`
- conversas do AI Assistant: `~/Library/Application Support/BunnyGrid/ai-chats.json`
- chaves de API: Keychain, serviços `app.bunnygrid.anthropic` (Claude) e `app.bunnygrid.openai` (ChatGPT)
- foto de perfil escolhida no app: `profile-photo.png` na mesma pasta (sem ela, usa a foto da conta do macOS)
- senhas: Keychain, serviço `app.bunnygrid.connections`

## O que já funciona (v0.7)

A janela segue o layout do Navicat Premium (ícones próprios em SF Symbols; nada da arte do Navicat é usado):

- **Barra principal**: Connection (menu de tipos), New Query, Table, View, Materialized View, Function, Role, Others, Query, Backup, Automation, Model, BI, Sobre, AI Assistant e conta. Os botões de tipo de objeto mostram aquela categoria na aba Objects. Role, Automation e BI estão desativados ("em breve").
- **Painel de navegação**: BunnyGrid Cloud (em breve) → My Connections → grupos (pastas) → conexões → bancos → schemas (PostgreSQL) → Tables / Views / Materialized Views / Functions / Queries / Backups → objetos. Abrir um nó conecta ou abre o banco; no PostgreSQL cada banco tem sua própria conexão. No rodapé: busca, localizar o objeto da aba aberta e recolher tudo.
- **Abas**: "Objects" fixa e abas como `payment @dvdrental.public (PostgreSQL)`. O título da janela segue o Navicat (`… - Table - BunnyGrid`).
- **Aba Objects**: Open / Design / New / Delete, Import / Export Wizard e busca; lista os objetos da pasta selecionada ou os bancos da conexão.
- **Aba de tabela**
  - barra: Table Profile, Begin Transaction, **Cell Editor**, **Filter & Sort**, **Columns** (mostrar/ocultar), **History** (SQL executado pela aba), **Fill with AI**, Data Profiling, Import, **Export**, Data Generation, Data Masking, Create BI Workspace (os itens sem destaque estão em breve)
  - grid com cabeçalho de duas linhas (nome e tipo: `# int4`, `numeric(5,2)`, `timestamp(6)`), coluna indicadora, célula em foco, `(Null)`, edição, exclusão e inserção pendentes com Apply/Discard em transação
  - rodapé: + − ✓ ✗ ↻ ■, primeira/anterior/página/próxima/última, registros por página (1000 por padrão), buscar no grid, Grid View / **Form View**
- **Aba de consulta**: editor com realce, autocomplete, histórico e exportação. **⌘S salva a consulta** na pasta Queries do banco (com nome); ⌘S de novo atualiza.
- **Design Table / New Table**: grade de campos (nome, tipo com sugestões do banco, Not Null, chave, Default), abas Fields / Indexes / Foreign Keys / Uniques / Triggers / Options / SQL Preview. Salvar gera `CREATE TABLE` ou `ALTER TABLE` (remover, renomear, mudar tipo/nulo/default, adicionar campo, renomear tabela) e roda numa transação no PostgreSQL e no SQLite; no SQLite, o que o `ALTER TABLE` não faz vira uma reconstrução da tabela. O que o designer não suporta (ex.: trocar a chave primária no PostgreSQL/MySQL) é avisado antes de salvar.
- **Visual do Navicat para macOS**: janela sem barra de título com o título ao lado dos botões da janela, barra de ícones ilustrados (mosaicos com gradiente e selos), controle **View** e avatar; **painel de navegação translúcido** (desfoque do que está atrás da janela, como no Finder); painel direito com abas **ⓘ Info** (cartão da conexão, banco ou tabela) e **AI**; aba Objects com barra de ícones, modo lista/grade e colunas Rows, Data Length, Engine, Created Date e Modified Date; resumo centralizado na barra de status; menu de contexto da conexão (estrela, cor, grupos, executar arquivo SQL…). Ícones são ilustrações SVG próprias (`Sources/BunnyGrid/Resources/Icons`), com gradientes, brilho e sombra, na paleta do Navicat mas sem copiar sua arte; bancos aparecem como cilindros na cor de cada motor, sem logotipos de terceiros. **Ícone do app** no formato do Icon Composer (`Resources/AppIcon.icon`): fundo, coelho e cilindro de moedas em camadas separadas, que o sistema renderiza com vidro, brilho especular e sombra nas aparências padrão, escura, tingida e transparente; o `bundle.sh` compila com o `actool` para `Assets.car` mais `AppIcon.icns` de reserva (macOS 14–15). `scripts/preview-icon.sh <pasta>` gera as prévias; `scripts/icon/build-layers.sh` refaz as camadas a partir da arte original. No macOS 26+ a cápsula View, o avatar, o item selecionado, as buscas e o campo do assistente usam Liquid Glass.
- **New Connection** (botão Connection, ⌘N): tela no estilo do Navicat com Connection Filter e Vendor Filter, grade ou lista, busca, Recents e o catálogo completo (bancos e serviços de nuvem de AWS, Google Cloud, Microsoft, Oracle, Alibaba, Huawei, Tencent, Fujitsu, HighGo, Kingbase, OceanBase, PingCAP). Serviços compatíveis com PostgreSQL ou MySQL/MariaDB funcionam de verdade, com porta e SSL pré-configurados; os demais aparecem como "Soon". **New Connection with URI** aceita `postgresql://`, `mysql://`, `mariadb://` e `sqlite:///`.
- **Aparência** (Settings → General): Sistema, Claro ou Escuro. O tema claro é o do modelo do Navicat.
- **Table Profile ▾**: salva e reaplica filtro, ordenação, colunas ocultas e máscaras de uma tabela.
- **Data Profiling**: por coluna, registros, nulos (com medidor de preenchimento), distintos, mínimo, máximo, média e os valores mais frequentes em barras.
- **Data Masking**: mascara colunas no grid e nas exportações (total, parcial, e-mail, últimos 4 dígitos); colunas mascaradas não são editáveis e o banco não é alterado.
- **Aba Objects** com Rows, Data Length, Engine (MySQL) e Comment.
- **Fluidez**: abas mantêm rolagem, seleção e texto ao alternar; ← → movem a célula em foco, Return ou digitar começa a editar; duplo clique na divisória do cabeçalho ajusta a coluna; Return / ← / → na árvore abrem, recolhem e expandem com animação; ⌘W fecha a aba, ⌃Tab / ⌃⇧Tab trocam de aba; os painéis lembram se estavam abertos.
- **Begin Transaction** (aba de tabela): abre uma conexão só da aba e executa `BEGIN`; as edições aplicadas ficam invisíveis para outras conexões até **Commit** (que aplica antes as edições pendentes) ou **Rollback**. Fechar a aba desfaz a transação.
- **Data Generation**: gera registros realistas (nomes, e-mails, telefones, cidades, empresas, UUIDs, datas, números, textos…), com o gerador sugerido pelo nome e tipo de cada campo, chaves automáticas puladas, respeito a `numeric(p,s)`, `smallint` e `varchar(n)`, prévia reproduzível e inserção numa transação.
- **Índices no Design Table**: criar, renomear, mudar campos/unicidade e remover índices (a chave primária fica protegida).
- **Chaves estrangeiras no Design Table** (aba Foreign Keys, como no Navicat): nome, campos, schema/banco, tabela e campos referenciados (menus com as tabelas e colunas do banco), On Delete e On Update. No PostgreSQL e no MySQL salvar gera `DROP`/`ADD CONSTRAINT … FOREIGN KEY` (as remoções antes das mudanças de campos, as inclusões depois); numa tabela nova as chaves vão no `CREATE TABLE`. O SQLite não altera chaves com `ALTER TABLE`, então o designer **reconstrói a tabela** como a documentação do SQLite recomenda (nova tabela, cópia das linhas, `DROP`, `RENAME` com `legacy_alter_table`, índices e triggers recriados, `PRAGMA foreign_key_check` antes do commit, `foreign_keys` restaurado no fim); isso também libera mudar tipo, Not Null, default e a chave primária no SQLite. Tabelas com CHECK, COLLATE, colunas geradas, WITHOUT ROWID ou STRICT são recusadas em vez de perder essas definições.
- **DDL**: SQLite mostra o `CREATE` guardado em `sqlite_master`, MySQL o `SHOW CREATE TABLE`, e o PostgreSQL monta do catálogo (colunas, PK/UNIQUE/CHECK/EXCLUDE, índices, comentários, triggers e as chaves estrangeiras como `ALTER TABLE` no fim). O painel DDL recarrega depois de salvar o design. O Dump SQL deixa as chaves do PostgreSQL para o fim do script e desliga `FOREIGN_KEY_CHECKS` no MySQL, para restaurar em qualquer ordem.
- **Import Wizard**: importa CSV/TSV numa tabela, com detecção do delimitador, linha de cabeçalho, vazio → NULL, prévia e mapeamento automático por nome; tudo numa transação.
- **Favorites**: favoritar tabelas/views (menu de contexto ou ⌘D), menu Favorites para abrir, e a estrela no rodapé do painel de navegação mostra só os favoritos.
- **⌘S** salva o que a aba atual tiver: edições do grid, consulta ou design.
- **Barra de status**: SQL da aba, alerta, "Record 5 of 1000 in page 1", "Last Refresh", e botões para mostrar/ocultar os painéis.
- **AI Assistant com Claude ou ChatGPT**, no modelo do assistente do Navicat 17 (manual público: chat, Ask AI, Fix with AI e opções). A plataforma é escolhida no **avatar da barra** (foto da conta do macOS ou uma escolhida, com o selo da IA ativa): ali se troca Claude/ChatGPT, cola a chave (verificada na hora) e escolhe o modelo. Claude usa a Messages API (padrão `claude-opus-5-5`, `fallbacks: "default"`); ChatGPT usa a Responses API (padrão `gpt-6-astra`, `store: false`). Chaves no Keychain ou em `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`; assinaturas Plus/Pro não incluem acesso à API.
  - **Chat** (painel direito): respostas em streaming com Markdown completo (títulos, listas, tabelas, citações), blocos de código com **Copy to New Query** e **More Options** (Insert at Editor Cursor, Replace Selection, Replace All, Append to Editor); **Attach Schemas** e **Attach Tabs** (estrutura de schemas e conteúdo de abas abertas como contexto), anexar arquivo, chips da tabela/schema; **Compare with Other Assistants** (a mesma pergunta para a outra IA, com abas Claude | ChatGPT); regenerar, editar a última pergunta, copiar; histórico com busca, renomear e apagar; Enter envia ou quebra linha (opção).
  - **Ask AI** no editor de consultas: clique abre as ações personalizadas (pergunta, formato Code/Natural Language, contexto Selected Text/All Text/Current Schema/Server Version, salvar e **fixar no menu**); segurar abre **Explain SQL, Optimize SQL, Beautify SQL, Convert SQL to Another Database Type** e as ações fixadas. Respostas em código mostram o **diff** com a consulta original (Show Diff) e aplicam no editor com desfazer (Append, Replace All, Replace Selection, Insert at Cursor) ou em New Query; respostas em texto têm **Continue in New Chat**.
  - **Fix with AI** e **Ask AI** (explicar o erro) aparecem quando uma consulta falha, usando a instrução que falhou e a mensagem do banco.
  - **Opções** (Settings › AI Assistant): por plataforma, Max Tokens, Effort (Low/Medium/High; os modelos atuais não aceitam temperature) e Instruction; Action for Enter key, Enable Compare with Other Assistants e Show AI features.
- **Model** (barra principal ou "Reverse Database to Model" no menu de contexto do banco/schema): aba com o diagrama ER do banco ou schema, lido do catálogo (tabelas, colunas, chaves primárias e estrangeiras). Layout automático em camadas (tabelas referenciadas à esquerda, relacionadas próximas), arrastar cartões, zoom (⌘+ / ⌘-, pinça, ajustar), clicar destaca as relações; linhas com pés de galinha (1:N, 1:1, opcional). As posições ficam em `model-layouts.json` por conexão, banco e schema. Exporta PNG/PDF e **Generate SQL** gera CREATE TABLE + chaves estrangeiras para SQLite, PostgreSQL, MySQL ou MariaDB (com tradução de tipos), para copiar, salvar ou abrir numa consulta. Flags de debug: `--open-model`, `--model-select TABELA`, `--model-export arquivo.png|pdf`, `--model-sql`.
- **Menus**: File, View (painéis), Table, Favorites (em breve), Tools.

## Licenças

- **Beekeeper Studio Community** é GPL-3 (e `src-commercial/` tem licença comercial). Copiar ou traduzir o código dele para Swift faz do BunnyGrid uma obra derivada sob GPL-3. Até que se decida isso, o Beekeeper serve só como referência de arquitetura e comportamento.
- Dependências atuais: PostgresNIO e MySQLNIO (MIT), SwiftNIO (Apache-2.0), SQLite do sistema.
