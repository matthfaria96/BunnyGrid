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

Com `--query`, `--explain` abre o plano da consulta em vez do resultado. No build de debug: `--demo-edits` (com `--open-table`) cria alterações pendentes de exemplo, `--focus-cell` foca uma célula, `--show-objects` abre a aba Objects com a pasta Tables selecionada, `--design TABELA` abre o Design Table (com `--design-section "Foreign Keys"` ou outra aba já selecionada e `--demo-fk` para uma chave alterada pendente), `--new-table` abre o New Table, `--connect-first` abre a primeira conexão salva, `--begin-transaction` e `--generate` (com `--open-table`) abrem o modo de transação e a Data Generation. Com `--open-table`, `--export-wizard`, `--import-wizard csv|json|sql [ARQUIVO]` e `--execute-sql ARQUIVO [--run-script]` abrem o Export Wizard, o Import Wizard e o Execute SQL File (`-export.format sql|xlsx|json|csv` escolhe o formato).
Também com `--open-table`: `--value-editor [COLUNA] [--row N]` abre o editor de valor sobre a célula, `--cell-editor [COLUNA]` abre o painel Cell Editor e `--demo-duplicate` duplica as duas primeiras linhas.

### Testes de integração com PostgreSQL

Com um PostgreSQL acessível (ex.: `brew install postgresql@17 && brew services start postgresql@17`):

```sh
BUNNYGRID_PG_PORT=5432 BUNNYGRID_PG_USER=$USER BUNNYGRID_PG_PASSWORD= BUNNYGRID_PG_DATABASE=postgres swift test
```

Sem `BUNNYGRID_PG_PORT` esses testes são pulados. Cada teste cria e apaga um schema próprio.

Um servidor descartável, sem mexer no PostgreSQL do sistema (a senha é exigida via TCP, para o teste de senha errada):

```sh
initdb -D /tmp/bg-pg -U bunny --auth-local=trust --auth-host=scram-sha-256 --pwprompt
pg_ctl -D /tmp/bg-pg -o "-p 54329 -k ''" -l /tmp/bg-pg.log start
createdb -h localhost -p 54329 -U bunny bunnytest
BUNNYGRID_PG_PORT=54329 BUNNYGRID_PG_USER=bunny BUNNYGRID_PG_PASSWORD=… BUNNYGRID_PG_DATABASE=bunnytest swift test --filter Postgres
pg_ctl -D /tmp/bg-pg stop
```

### Testes de integração com MySQL / MariaDB

```sh
BUNNYGRID_MYSQL_PORT=3306 BUNNYGRID_MYSQL_USER=root BUNNYGRID_MYSQL_PASSWORD=… swift test --filter MySQL
# MariaDB: acrescente BUNNYGRID_MYSQL_KIND=mariadb
```

O usuário precisa de CREATE/DROP DATABASE: cada teste cria e apaga um banco próprio. Sem `BUNNYGRID_MYSQL_PORT` esses testes são pulados.

Os testes de SSL, socket e túnel SSH (`ConnectivityIntegrationTests.swift`) usam outras variáveis: `BUNNYGRID_TLS_PG_PORT`, `BUNNYGRID_TLS_PG_USER` e `BUNNYGRID_TLS_PG_CERTS` (PostgreSQL com `ssl = on` e uma CA própria), `BUNNYGRID_PG_SOCKET_DIR`, e `BUNNYGRID_SSH_PORT`, `BUNNYGRID_SSH_USER` e `BUNNYGRID_SSH_KEYS` (um `sshd` com chaves de teste). O comentário no topo do arquivo descreve os arquivos esperados. Com o Remote Login desligado, um `sshd -D -f <config>` do próprio usuário numa porta alta serve.

No build de debug, `--edit-connection` abre o editor da primeira conexão salva (`-connectionTab ssl|ssh|advanced` escolhe a aba) e `--test-connection` roda o Test Connection ao abrir.

## Estrutura

```
Sources/
  BunnyGridCore/          núcleo sem UI (testável)
    Models/               ConnectionConfig, objetos, colunas, CellValue, QueryResult
    Drivers/              protocolo DatabaseDriver + SQLite (libsqlite3), PostgreSQL (PostgresNIO), MySQL/MariaDB (MySQLNIO)
    SQL/                  SQLDialect (aspas, SELECT paginado, EXPLAIN), SQLSplitter (divide scripts, comando sob o cursor) e QueryPlan (árvore do plano)
    Network/              túnel SSH (Citadel), host keys, configuração SSL e endpoint (TCP, socket ou túnel) usado pelos drivers
    Transfer/             zip e Excel (.xlsx), leitura de JSON para importar, execução de scripts .sql com progresso
    Sync/                 Data Transfer entre motores, Structure Synchronization (diff + script) e Data Synchronization
    Backup/               formato .bgbackup, BackupStore (pasta por conexão/banco/schema), criar, restaurar e extrair SQL; cópia de arquivo SQLite (sqlite3_backup)
    Automation/           BatchJob, JobSchedule (cron, próximas execuções, StartCalendarInterval), JobRunner, launch agents, runner headless
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
- senhas: Keychain, serviço `app.bunnygrid.connections` (conta `<id>` para o banco, `<id>.ssh` para a senha SSH ou passphrase da chave, `<id>.ssl-key` para a passphrase da chave do certificado de cliente)
- backups: `backups/<id da conexão>/<banco>/<schema ou _>/<aaaaMMddHHmmss>.bgbackup`
- jobs: `automation/jobs.json`; cada execução em `automation/runs/<id>.json` (com o log) e cópia em texto em `automation/logs/`; saída do launchd em `automation/logs/launchd-<id do job>.log`
- agendamentos: `~/Library/LaunchAgents/app.bunnygrid.job.<id>.plist`, só para jobs com agendamento ativo salvo
- host keys SSH aceitas no primeiro uso: `~/Library/Application Support/BunnyGrid/ssh-known-hosts.json`

## O que já funciona (v0.7)

A janela segue o layout do Navicat Premium (ícones próprios em SF Symbols; nada da arte do Navicat é usado):

- **Barra principal**: Connection (menu de tipos), New Query, Table, View, Materialized View, Function, Role, Others, Query, Backup, Automation, Model, BI, Sobre, AI Assistant e conta. Os botões de tipo de objeto mostram aquela categoria na aba Objects. Role e BI estão desativados ("em breve"); Automation abre a janela de jobs e Backup mostra a pasta Backups.
- **Painel de navegação**: BunnyGrid Cloud (em breve) → My Connections → grupos (pastas) → conexões → bancos → schemas (PostgreSQL) → Tables / Views / Materialized Views / Functions / Queries / Backups → objetos. Abrir um nó conecta ou abre o banco; no PostgreSQL cada banco tem sua própria conexão. No rodapé: busca, localizar o objeto da aba aberta e recolher tudo.
- **Abas**: "Objects" fixa e abas como `payment @dvdrental.public (PostgreSQL)`. O título da janela segue o Navicat (`… - Table - BunnyGrid`).
- **Aba Objects**: Open / Design / New / Delete, Import / Export Wizard e busca; lista os objetos da pasta selecionada ou os bancos da conexão.
- **Aba de tabela**
  - barra: Table Profile, Begin Transaction, **Cell Editor**, **Filter & Sort**, **Columns** (mostrar/ocultar), **History** (SQL executado pela aba), **Fill with AI**, Data Profiling, Import, **Export**, Data Generation, Data Masking, Create BI Workspace (os itens sem destaque estão em breve)
  - grid com cabeçalho de duas linhas (nome e tipo: `# int4`, `numeric(5,2)`, `timestamp(6)`), coluna indicadora, célula em foco, `(Null)`, edição, exclusão e inserção pendentes com Apply/Discard em transação
  - rodapé: + − ✓ ✗ ↻ ■, primeira/anterior/página/próxima/última, registros por página (1000 por padrão), buscar no grid, Grid View / **Form View**
- **Aba de consulta**: editor com realce, autocomplete, histórico e exportação. **⌘S salva a consulta** na pasta Queries do banco (com nome); ⌘S de novo atualiza.
  - **Run** (⌘↩) roda a seleção ou o editor inteiro; o menu do Run e o menu de contexto do editor têm **Run Selected**, **Run Current Statement** (⌘⇧↩, o comando sob o cursor) e **Run All**. **Beautify SQL** (⌘⇧B) formata localmente.
  - **Explain** mostra o plano do comando selecionado ou sob o cursor sem executá-lo (`EXPLAIN QUERY PLAN` no SQLite, `EXPLAIN (FORMAT JSON)` no PostgreSQL, `EXPLAIN FORMAT=JSON` no MySQL/MariaDB) numa aba **Explain** com a árvore do plano (custo, linhas, condições) e o resultado bruto em Data.
  - **Stop** (⌘.) cancela no servidor: `pg_cancel_backend` e `KILL QUERY` por uma segunda conexão, `sqlite3_interrupt` no SQLite.
  - Cada aba de consulta tem **conexão própria** (aberta na primeira execução, com as Initial Queries, fechada com a aba): uma transação aberta no editor não se mistura com edições aplicadas nas abas de tabela. SQLite em memória continua na conexão do banco.
  - Resultados leem no máximo o limite de Options › Records (1000 por padrão); o rodapé mostra **Load More** e **Fetch All** para consultas de leitura.
- **Design Table / New Table**: grade de campos (nome, tipo com sugestões do banco, Not Null, chave, Default), abas Fields / Indexes / Foreign Keys / Uniques / Triggers / Options / SQL Preview. Salvar gera `CREATE TABLE` ou `ALTER TABLE` (remover, renomear, mudar tipo/nulo/default, adicionar campo, renomear tabela) e roda numa transação no PostgreSQL e no SQLite; no SQLite, o que o `ALTER TABLE` não faz vira uma reconstrução da tabela. O que o designer não suporta (ex.: trocar a chave primária no PostgreSQL/MySQL) é avisado antes de salvar.
- **Visual do Navicat para macOS**: janela sem barra de título com o título ao lado dos botões da janela, barra de ícones ilustrados (mosaicos com gradiente e selos), controle **View** e avatar; **painel de navegação translúcido** (desfoque do que está atrás da janela, como no Finder); painel direito com abas **ⓘ Info** (cartão da conexão, banco ou tabela) e **AI**; aba Objects com barra de ícones, modo lista/grade e colunas Rows, Data Length, Engine, Created Date e Modified Date; resumo centralizado na barra de status; menu de contexto da conexão (estrela, cor, grupos, executar arquivo SQL…). Ícones são ilustrações SVG próprias (`Sources/BunnyGrid/Resources/Icons`), com gradientes, brilho e sombra, na paleta do Navicat mas sem copiar sua arte; bancos aparecem como cilindros na cor de cada motor, sem logotipos de terceiros. **Ícone do app** no formato do Icon Composer (`Resources/AppIcon.icon`): fundo, coelho e cilindro de moedas em camadas separadas, que o sistema renderiza com vidro, brilho especular e sombra nas aparências padrão, escura, tingida e transparente; o `bundle.sh` compila com o `actool` para `Assets.car` mais `AppIcon.icns` de reserva (macOS 14–15). `scripts/preview-icon.sh <pasta>` gera as prévias; `scripts/icon/build-layers.sh` refaz as camadas a partir da arte original. No macOS 26+ a cápsula View, o avatar, o item selecionado, as buscas e o campo do assistente usam Liquid Glass.
- **New Connection** (botão Connection, ⌘N): tela no estilo do Navicat com Connection Filter e Vendor Filter, grade ou lista, busca, Recents e o catálogo completo (bancos e serviços de nuvem de AWS, Google Cloud, Microsoft, Oracle, Alibaba, Huawei, Tencent, Fujitsu, HighGo, Kingbase, OceanBase, PingCAP). Serviços compatíveis com PostgreSQL ou MySQL/MariaDB funcionam de verdade, com porta e SSL pré-configurados; os demais aparecem como "Soon". **New Connection with URI** aceita `postgresql://`, `mysql://`, `mariadb://` e `sqlite:///`.
- **Aparência** (Settings → General): Sistema, Claro ou Escuro. O tema claro é o do modelo do Navicat.
- **Table Profile ▾**: salva e reaplica filtro, ordenação, colunas ocultas e máscaras de uma tabela; atualiza um perfil com a visão atual e marca um perfil para abrir a tabela já com ele.
- **Data Profiling**: por coluna, registros, nulos (com medidor de preenchimento), distintos, mínimo, máximo, média e os valores mais frequentes em barras.
- **Data Masking**: mascara colunas no grid e nas exportações (total, parcial, e-mail, últimos 4 dígitos); colunas mascaradas não são editáveis e o banco não é alterado.
- **Editor de valor** (Cell Editors do Navicat): ⌥↩, duplo clique num valor longo ou "Open in Value Editor" abre um popover sobre a célula; o mesmo editor fica no painel **Cell Editor**. O editor segue o tipo da coluna: texto multilinha (sem aspas inteligentes), **JSON** com Beautify, Minify e validação (a ordem das chaves é mantida), **blobs** em hex ou imagem com Load from File / Save to File, e **calendário e hora** para colunas de data. NULL, vazio e DEFAULT aplicam na hora. No grid, quebras de linha aparecem como ⏎ e blobs como "(PNG) 14 KB".
- **Duplicar registros** (botão ⧉ no rodapé ou menu de contexto): copia as linhas como inserções pendentes, sem as chaves geradas (serial, identity, auto-increment, chave com default).
- **Copy As** no menu de contexto do grid: INSERT e UPDATE (aba de tabela), TSV com ou sem nomes, CSV, JSON (colunas na ordem do grid) e tabela Markdown.
- **Parâmetros tipados**: as edições vão ao banco como parâmetros (`$1` / `?`) com o tipo da coluna (inteiro, double, booleano, bytes, data/hora, NULL), em vez de literais de texto.
- **Aba Objects** com Rows, Data Length, Engine (MySQL) e Comment.
- **Fluidez**: abas mantêm rolagem, seleção e texto ao alternar; ← → movem a célula em foco, Return ou digitar começa a editar; duplo clique na divisória do cabeçalho ajusta a coluna; Return / ← / → na árvore abrem, recolhem e expandem com animação; ⌘W fecha a aba, ⌃Tab / ⌃⇧Tab trocam de aba; os painéis lembram se estavam abertos.
- **Begin Transaction** (aba de tabela): abre uma conexão só da aba e executa `BEGIN`; as edições aplicadas ficam invisíveis para outras conexões até **Commit** (que aplica antes as edições pendentes) ou **Rollback**. Fechar a aba desfaz a transação.
- **Data Generation**: gera registros realistas (nomes, e-mails, telefones, cidades, empresas, UUIDs, datas, números, textos…), com o gerador sugerido pelo nome e tipo de cada campo, chaves automáticas puladas, respeito a `numeric(p,s)`, `smallint` e `varchar(n)`, prévia reproduzível e inserção numa transação.
- **Índices no Design Table**: criar, renomear, mudar campos/unicidade e remover índices (a chave primária fica protegida).
- **Chaves estrangeiras no Design Table** (aba Foreign Keys, como no Navicat): nome, campos, schema/banco, tabela e campos referenciados (menus com as tabelas e colunas do banco), On Delete e On Update. No PostgreSQL e no MySQL salvar gera `DROP`/`ADD CONSTRAINT … FOREIGN KEY` (as remoções antes das mudanças de campos, as inclusões depois); numa tabela nova as chaves vão no `CREATE TABLE`. O SQLite não altera chaves com `ALTER TABLE`, então o designer **reconstrói a tabela** como a documentação do SQLite recomenda (nova tabela, cópia das linhas, `DROP`, `RENAME` com `legacy_alter_table`, índices e triggers recriados, `PRAGMA foreign_key_check` antes do commit, `foreign_keys` restaurado no fim); isso também libera mudar tipo, Not Null, default e a chave primária no SQLite. Tabelas com CHECK, COLLATE, colunas geradas, WITHOUT ROWID ou STRICT são recusadas em vez de perder essas definições.
- **DDL**: SQLite mostra o `CREATE` guardado em `sqlite_master`, MySQL o `SHOW CREATE TABLE`, e o PostgreSQL monta do catálogo (colunas, PK/UNIQUE/CHECK/EXCLUDE, índices, comentários, triggers e as chaves estrangeiras como `ALTER TABLE` no fim). O painel DDL recarrega depois de salvar o design. O Dump SQL deixa as chaves do PostgreSQL para o fim do script e desliga `FOREIGN_KEY_CHECKS` no MySQL, para restaurar em qualquer ordem.
- **Import Wizard**: importa CSV/TSV ou JSON (array de objetos, objeto com um array, JSON Lines; números, booleanos e NULL mantêm o tipo) numa tabela, com detecção do delimitador, linha de cabeçalho, vazio → NULL, prévia e mapeamento automático por nome, tudo numa transação; ou roda um arquivo .sql no banco.
- **Export Wizard**: várias tabelas e views de uma vez, em CSV (delimitador, cabeçalho), JSON (chaves na ordem das colunas), SQL (CREATE e DROP opcionais, INSERT com N linhas por comando) ou Excel .xlsx (um arquivo por objeto ou uma pasta de trabalho com uma planilha por objeto). O .xlsx é escrito por código próprio (`Sources/BunnyGridCore/Transfer`), sem dependências. O menu Export do grid também grava Excel.
- **Execute SQL File** (menu da conexão ou do banco): divide o arquivo em comandos (inclusive `DELIMITER` do mysqldump), mostra o progresso, para no primeiro erro ou continua e lista os erros, e pode rodar tudo numa transação. **Dump SQL File** desliga a checagem de chaves estrangeiras no MySQL, usa nomes sem o banco (restaura em qualquer banco) e recria as sequências `serial` do PostgreSQL.
- **Data Transfer** (menu Tools ou menu de contexto do banco/schema): copia tabelas escolhidas (estrutura e/ou registros) de uma conexão/banco/schema para outra, entre SQLite, PostgreSQL e MySQL/MariaDB em qualquer direção, ou grava um arquivo .sql no dialeto escolhido. Tipos traduzidos entre motores (reaproveita a tradução do Model, com reserva pela categoria do valor), colunas auto-numeradas viram `serial` / `AUTO_INCREMENT` / `INTEGER PRIMARY KEY` (e a sequência do PostgreSQL avança depois da cópia), índices e chaves estrangeiras depois dos dados. Opções: criar tabelas, apagar as do destino antes, copiar registros, índices, chaves, continuar no erro (o lote que falha é refeito linha a linha) e linhas por lote; INSERTs com vários registros e parâmetros tipados, progresso, log e Stop.
- **Structure Synchronization**: compara dois schemas (tabelas, colunas, tipo, nulo, default, auto incremento, chave primária, índices, chaves estrangeiras e, entre motores iguais, views), lista o que criar, modificar e apagar com caixas por objeto, mostra o script de deploy e o executa (numa transação no PostgreSQL e no SQLite; no SQLite, o que o ALTER TABLE não faz vira a reconstrução da tabela do designer).
- **Data Synchronization**: compara tabelas com a mesma chave primária (valores comparados pelo significado: `1`/`true`, `12.5`/`"12.50"`), mostra inserções, atualizações e exclusões com caixas por tipo e por linha, copia o script e aplica numa transação com parâmetros tipados.
- **Favorites**: favoritar tabelas/views (menu de contexto ou ⌘D), menu Favorites para abrir, e a estrela no rodapé do painel de navegação mostra só os favoritos.
- **⌘S** salva o que a aba atual tiver: edições do grid, consulta ou design.
- **Barra de status**: SQL da aba, alerta, "Record 5 of 1000 in page 1", "Last Refresh", e botões para mostrar/ocultar os painéis.
- **AI Assistant com Claude ou ChatGPT**, no modelo do assistente do Navicat 17 (manual público: chat, Ask AI, Fix with AI e opções). A plataforma é escolhida no **avatar da barra** (foto da conta do macOS ou uma escolhida, com o selo da IA ativa): ali se troca Claude/ChatGPT, cola a chave (verificada na hora) e escolhe o modelo. Claude usa a Messages API (padrão `claude-opus-5-5`, `fallbacks: "default"`); ChatGPT usa a Responses API (padrão `gpt-6-astra`, `store: false`). Chaves no Keychain ou em `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`; assinaturas Plus/Pro não incluem acesso à API.
  - **Chat** (painel direito): respostas em streaming com Markdown completo (títulos, listas, tabelas, citações), blocos de código com **Copy to New Query** e **More Options** (Insert at Editor Cursor, Replace Selection, Replace All, Append to Editor); **Attach Schemas** e **Attach Tabs** (estrutura de schemas e conteúdo de abas abertas como contexto), anexar arquivo, chips da tabela/schema; **Compare with Other Assistants** (a mesma pergunta para a outra IA, com abas Claude | ChatGPT); regenerar, editar a última pergunta, copiar; histórico com busca, renomear e apagar; Enter envia ou quebra linha (opção).
  - **Ask AI** no editor de consultas: clique abre as ações personalizadas (pergunta, formato Code/Natural Language, contexto Selected Text/All Text/Current Schema/Server Version, salvar e **fixar no menu**); segurar abre **Explain SQL, Optimize SQL, Beautify SQL, Convert SQL to Another Database Type** e as ações fixadas. Respostas em código mostram o **diff** com a consulta original (Show Diff) e aplicam no editor com desfazer (Append, Replace All, Replace Selection, Insert at Cursor) ou em New Query; respostas em texto têm **Continue in New Chat**.
  - **Fix with AI** e **Ask AI** (explicar o erro) aparecem quando uma consulta falha, usando a instrução que falhou e a mensagem do banco.
  - **Opções** (Settings › AI Assistant): por plataforma, Max Tokens, Effort (Low/Medium/High; os modelos atuais não aceitam temperature) e Instruction; Action for Enter key, Enable Compare with Other Assistants e Show AI features.
- **Model** (barra principal ou "Reverse Database to Model" no menu de contexto do banco/schema): aba com o diagrama ER do banco ou schema, lido do catálogo (tabelas, colunas, chaves primárias e estrangeiras). Layout automático em camadas (tabelas referenciadas à esquerda, relacionadas próximas), arrastar cartões, zoom (⌘+ / ⌘-, pinça, ajustar), clicar destaca as relações; linhas com pés de galinha (1:N, 1:1, opcional). As posições ficam em `model-layouts.json` por conexão, banco e schema. Exporta PNG/PDF e **Generate SQL** gera CREATE TABLE + chaves estrangeiras para SQLite, PostgreSQL, MySQL ou MariaDB (com tradução de tipos), para copiar, salvar ou abrir numa consulta. Flags de debug: `--open-model`, `--model-select TABELA`, `--model-export arquivo.png|pdf`, `--model-sql`.
- **Backup** (botão Backup da barra principal, pasta Backups da aba Objects ou Tools › New Backup…): backup do banco ou schema com comentário, escolha de objetos, estrutura e/ou dados; no SQLite também cópia do arquivo inteiro pela API `sqlite3_backup`. A lista mostra data, tamanho, objetos, linhas, tipo e comentário; **Restore** no mesmo banco ou em outro banco aberto do mesmo motor (Drop existing, Continue on error, transação única, com progresso e erros), **Extract SQL** para um .sql, editar comentário, mostrar no Finder, apagar (vai para o Lixo).
  - Formato `.bgbackup` (versão 1): `BGBACKUP` + versão (UInt32 LE) + tamanho do manifesto (UInt32 LE) + manifesto JSON (conexão, banco, schema, data, comentário, objetos, linhas) + o script SQL (ou o arquivo SQLite) comprimido em DEFLATE puro (`COMPRESSION_ZLIB` da Apple; `zlib.decompress(dados, -15)` no Python). O script vem do Dump SQL, com DROP … IF EXISTS e INSERTs de 100 linhas.
- **Automation** (botão Automation, Tools › Automation ⇧⌘J): janela com os batch jobs. Cada job tem passos em ordem (Run Saved Query, Run SQL, Execute SQL File, Backup, Export com as opções do Export Wizard e pasta de saída, opcionalmente datada), "continuar quando um passo falha", agendamento (manual, uma vez, de hora em hora, diário, semanal, mensal ou cron de 5 campos com as próximas 5 execuções), notificações de sucesso e falha, e o histórico com status, duração e log de cada execução. Start roda na hora, dentro do app.
  - Agendamentos rodam com o app fechado: salvar um agendamento ativo grava `~/Library/LaunchAgents/app.bunnygrid.job.<id>.plist` (`StartCalendarInterval`) e carrega com `launchctl bootstrap`; desligar o agendamento ou apagar o job faz `bootout` e remove o plist. O launchd executa `BunnyGrid --run-job <id> --scheduled`, modo headless do mesmo executável: lê conexões, consultas e jobs da pasta de dados, as senhas do Keychain, conecta pelo mesmo caminho (SSH, SSL, socket, Initial Queries), grava a execução e notifica. `SMAppService.agent` não foi usado porque só registra plists fixos dentro do bundle, sem horário por job.
  - Para testar sem tocar em `~/Library/LaunchAgents`: `BUNNYGRID_LAUNCH_AGENTS_DIR=<pasta>` grava os plists ali e não chama o launchctl. Rodar um job à mão: `BUNNYGRID_DATA_DIR=<pasta> build/BunnyGrid.app/Contents/MacOS/BunnyGrid --run-job <id>` (saída 0 = sucesso, 1 = falhou, 2 = job não encontrado). Flag de debug: `-automationPane steps|schedule|history`.
- **Menus**: File, View (painéis), Table, Favorites (em breve), Tools.

## Licenças

- **Beekeeper Studio Community** é GPL-3 (e `src-commercial/` tem licença comercial). Copiar ou traduzir o código dele para Swift faz do BunnyGrid uma obra derivada sob GPL-3. Até que se decida isso, o Beekeeper serve só como referência de arquitetura e comportamento.
- Dependências atuais: PostgresNIO e MySQLNIO (MIT), SwiftNIO (Apache-2.0), SQLite do sistema.
