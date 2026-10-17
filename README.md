# BunnyGrid

Cliente de bancos de dados nativo para macOS, em Swift e SwiftUI.
Conecta em **SQLite, PostgreSQL, MySQL, MariaDB, SQL Server (e Azure SQL), MongoDB e Redis**. Mostra a árvore de objetos, abre tabelas num grid paginado e executa SQL num editor com realce de sintaxe.

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

Com `--query`, `--explain` abre o plano da consulta em vez do resultado, e no build de debug `--demo-result-edits` cria edições pendentes no resultado, `--result-form` abre o Form View e `--result-profiling` o Data Profiling do resultado. No build de debug: `--demo-edits` (com `--open-table`) cria alterações pendentes de exemplo, `--focus-cell` foca uma célula, `--show-objects` abre a aba Objects com a pasta Tables selecionada, `--design TABELA` abre o Design Table (com `--design-section "Foreign Keys"` ou outra aba já selecionada e `--demo-fk` para uma chave alterada pendente), `--new-table` abre o New Table, `--connect-first` abre a primeira conexão salva, `--begin-transaction` e `--generate` (com `--open-table`) abrem o modo de transação e a Data Generation. Com `--open-table`, `--export-wizard`, `--import-wizard csv|json|excel|sql [ARQUIVO]` e `--execute-sql ARQUIVO [--run-script]` abrem o Export Wizard, o Import Wizard e o Execute SQL File (`-export.format sql|xlsx|json|csv` escolhe o formato).
Também com `--open-table`: `--value-editor [COLUNA] [--row N]` abre o editor de valor sobre a célula, `--cell-editor [COLUNA]` abre o painel Cell Editor e `--demo-duplicate` duplica as duas primeiras linhas.

Medidas de desempenho: `--bench CENÁRIO` (no build de debug, ou em release com `swift build -c release -Xswiftc -DBUNNYGRID_BENCH`) executa ações roteirizadas e grava os tempos em `BUNNYGRID_PERF_LOG` (uma linha por medida: nome, ms, detalhe), depois fecha o app. Cenários: `launch`, `connect`, `expand` e `objects` (banco com milhares de tabelas), `open-table`, `scroll` e `resize` (tabela `events`, ou `--bench-table NOME`), `tabs`, `typing` e `autocomplete` (com `--bench-script ARQUIVO.sql`), `query100k` (`--bench-rows N`) e `er`. Os intervalos também aparecem no Instruments (Points of Interest, `PerfTrace`). `BUNNYGRID_BENCH=1 swift test` roda o benchmark do realce de sintaxe.

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

O usuário precisa de CREATE/DROP DATABASE e CREATE USER: cada teste cria e apaga um banco próprio. Sem `BUNNYGRID_MYSQL_PORT` esses testes são pulados.

Um MySQL descartável do Homebrew (`brew install mysql`), sem mexer no `my.cnf` nem nos dados do sistema (`--no-defaults`; dados, socket, pid, log e certificados ficam numa pasta só):

```sh
scripts/test-servers/mysql.sh start /tmp/bg-mysql   # inicializa na primeira vez, porta 33071 (BUNNYGRID_MYSQL_PORT muda)
eval "$(scripts/test-servers/mysql.sh env /tmp/bg-mysql)"
swift test --filter MySQL
scripts/test-servers/mysql.sh stop /tmp/bg-mysql
```

O script cria uma CA e certificados de servidor e de cliente, sobe o servidor com SSL (sem `require_secure_transport`, para testar com e sem SSL) e os usuários `bunny` / `bunnypass`, `certuser` (`REQUIRE X509`) e `nopass` (sem senha, útil para abrir o app sem Keychain). O `env` exporta também `BUNNYGRID_MYSQL_SSL_CA`, `_SSL_CERT`, `_SSL_KEY`, `_SSL_USER` e `BUNNYGRID_MYSQL_SOCKET`; se o caminho do socket passar do limite de 104 bytes, ele fica num link curto em `$TMPDIR`. Para o caso do túnel, acrescente `BUNNYGRID_SSH_PORT`, `_USER` e `_KEYS` (um `sshd -f <config>` do usuário com a chave `user_ecdsa` serve).

MariaDB pelo Docker (colima):

```sh
docker run -d --name bg-mariadb -p 127.0.0.1:33081:3306 -e MARIADB_ROOT_PASSWORD=bunnypass mariadb:11
BUNNYGRID_MYSQL_KIND=mariadb BUNNYGRID_MYSQL_PORT=33081 BUNNYGRID_MYSQL_USER=root BUNNYGRID_MYSQL_PASSWORD=bunnypass swift test --filter MySQL
docker rm -f bg-mariadb
```

Os testes de SSL, socket e túnel SSH (`ConnectivityIntegrationTests.swift`) usam outras variáveis: `BUNNYGRID_TLS_PG_PORT`, `BUNNYGRID_TLS_PG_USER` e `BUNNYGRID_TLS_PG_CERTS` (PostgreSQL com `ssl = on` e uma CA própria), `BUNNYGRID_PG_SOCKET_DIR`, e `BUNNYGRID_SSH_PORT`, `BUNNYGRID_SSH_USER` e `BUNNYGRID_SSH_KEYS` (um `sshd` com chaves de teste). O comentário no topo do arquivo descreve os arquivos esperados. Com o Remote Login desligado, um `sshd -D -f <config>` do próprio usuário numa porta alta serve.

### Testes de integração com SQL Server

Com um SQL Server acessível. Num Mac com Apple Silicon, o contêiner oficial roda sob Rosetta (colima ou Docker Desktop):

```sh
docker run -d --name bg-mssql --platform linux/amd64 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='…' -p 14331:1433 mcr.microsoft.com/mssql/server:2022-latest
BUNNYGRID_MSSQL_PORT=14331 BUNNYGRID_MSSQL_PASSWORD='…' swift test --filter SQLServer
docker rm -f bg-mssql
```

`BUNNYGRID_MSSQL_HOST` e `BUNNYGRID_MSSQL_USER` (padrão `sa`) mudam o destino. O login precisa de CREATE DATABASE: cada teste cria e apaga um banco próprio. Sem `BUNNYGRID_MSSQL_PORT` esses testes são pulados; os testes do protocolo (`TDSProtocolTests`) rodam sempre, com bytes de exemplo.

### Testes de integração com Redis

```sh
redis-server --port 63791 --dir /tmp/bg-redis --requirepass segredo --daemonize yes
BUNNYGRID_REDIS_PORT=63791 BUNNYGRID_REDIS_PASSWORD=segredo swift test --filter Redis
redis-cli -p 63791 -a segredo shutdown nosave
```

Usa o db 9 e chaves `bunnygrid-test:*`. Opcionais: `BUNNYGRID_REDIS_TLS_PORT` + `BUNNYGRID_REDIS_TLS_CA` (e `_TLS_CERT` / `_TLS_KEY` para certificado de cliente) para um `redis-server --tls-port`, e `BUNNYGRID_REDIS_SOCKET` para socket Unix. O caminho do socket precisa ter menos de 104 caracteres (limite do macOS); um link simbólico curto para o socket serve. Com o módulo RedisJSON carregado (`--loadmodule …/rejson.so`, incluído no `redis` do Homebrew) o teste de JSON também roda.
### Testes de integração com MongoDB
Com um `mongod` acessível (ex.: `brew install mongodb-community`). No macOS o `--fork` não é aceito; rode em segundo plano:
mongod --dbpath /tmp/bg-mongo --port 27071 --bind_ip 127.0.0.1 --logpath /tmp/bg-mongo.log &
BUNNYGRID_MONGO_PORT=27071 swift test --filter Mongo
# Com autenticação (mongod --auth e um usuário root em admin; opcionalmente outro criado com mechanisms: ["SCRAM-SHA-1"]):
BUNNYGRID_MONGO_PORT=27071 BUNNYGRID_MONGO_USER=bunny BUNNYGRID_MONGO_PASSWORD=… \
  BUNNYGRID_MONGO_SHA1_USER=sha1user BUNNYGRID_MONGO_SHA1_PASSWORD=… swift test --filter Mongo
Cada teste cria e apaga um banco próprio. Sem `BUNNYGRID_MONGO_PORT` esses testes são pulados. No build de debug, com `--connect-first` numa conexão MongoDB: `--open-collection NOME [--mongo-view grid|tree|json] [--mongo-filter '{…}'] [--edit-document]` abre o visualizador de coleção e `--mongo-shell 'db.c.find()' [--explain]` abre uma aba de shell e executa.

Aba **Databases** do Edit Connection: no SQLite, arquivos anexados (`ATTACH … AS alias`) em toda conexão aberta, ao lado de main; no PostgreSQL, MySQL, SQL Server e MongoDB, quais bancos aparecem no navegador (List Databases lê os do servidor; o banco da conexão sempre aparece). A aba HTTP do Navicat não existe aqui: o túnel HTTP depende do script de túnel do Navicat no servidor; use SSH.

No build de debug, `--edit-connection` abre o editor da primeira conexão salva (`-connectionTab ssl|ssh|advanced|databases` escolhe a aba) e `--test-connection` roda o Test Connection ao abrir.

## Estrutura

```
Sources/
  BunnyGridCore/          núcleo sem UI (testável)
    Models/               ConnectionConfig, objetos, colunas, CellValue, QueryResult
    Drivers/              protocolo DatabaseDriver + SQLite (libsqlite3), PostgreSQL (PostgresNIO), MySQL/MariaDB (MySQLNIO), SQL Server (cliente TDS próprio em `Drivers/TDS`), MongoDB (cliente próprio), Redis (RedisDriver)
    Redis/                cliente RESP2/RESP3 próprio em SwiftNIO, parser de linha de comando (aspas do redis-cli), KeyValueDatabaseDriver, árvore de pastas das chaves, INFO/CLIENT LIST/SLOWLOG
    Mongo/                BSON, OP_MSG sobre SwiftNIO, SCRAM, mongodb+srv (dnssd), parser do shell, DocumentDatabaseDriver, achatamento para o grid
    QueryBuilder/         modelo do SELECT do Query Builder (BuilderQuery), geração de SQL por dialeto e parser de SELECTs simples
    SQL/                  SQLDialect (aspas, SELECT paginado, EXPLAIN), SQLSplitter (divide scripts, comando sob o cursor) e QueryPlan (árvore do plano)
    Network/              túnel SSH (Citadel), host keys, configuração SSL e endpoint (TCP, socket ou túnel) usado pelos drivers
    Transfer/             zip (STORE/DEFLATE) e Excel (.xlsx, escrita e leitura), leitura de JSON para importar, execução de scripts .sql com progresso
    Sync/                 Data Transfer entre motores, Structure Synchronization (diff + script) e Data Synchronization
    Backup/               formato .bgbackup, BackupStore (pasta por conexão/banco/schema), criar, restaurar e extrair SQL; cópia de arquivo SQLite (sqlite3_backup)
    Automation/           BatchJob, JobSchedule (cron, próximas execuções, StartCalendarInterval), JobRunner, launch agents, runner headless
    Storage/              ConnectionStore (JSON em Application Support) e KeychainStore (senhas)
  BunnyGrid/              app SwiftUI
    App/                  BunnyGridApp, AppModel (conexões e sessões), Session (árvore e abas)
    Views/                janela, barra lateral, editor de conexão, abas de tabela e de consulta
    Redis/                navegador de chaves, visualizador por tipo, Console, Server Monitor, New Key
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

- **Barra principal**: Connection (menu de tipos), New Query, Table, View, Materialized View, Function, Role, Others, Query, Backup, Automation, Model, BI, Sobre, AI Assistant e conta. Os botões de tipo de objeto mostram aquela categoria na aba Objects. Role está desativado ("em breve"); BI abre um workspace novo ou um salvo; Automation abre a janela de jobs e Backup mostra a pasta Backups.
- **Painel de navegação**: BunnyGrid Cloud (em breve) → My Connections → grupos (pastas) → conexões → bancos → schemas (PostgreSQL) → Tables / Views / Materialized Views / Functions / Queries / Backups → objetos. Abrir um nó conecta ou abre o banco; no PostgreSQL cada banco tem sua própria conexão. No rodapé: busca, localizar o objeto da aba aberta e recolher tudo.
- **Abas**: "Objects" fixa e abas como `payment @dvdrental.public (PostgreSQL)`. O título da janela segue o Navicat (`… - Table - BunnyGrid`).
- **Aba Objects**: Open / Design / New / Delete, Import / Export Wizard e busca; lista os objetos da pasta selecionada ou os bancos da conexão.
- **Aba de tabela**
  - barra: Table Profile, Begin Transaction, **Cell Editor**, **Filter & Sort**, **Columns** (mostrar/ocultar), **History** (SQL executado pela aba), **Fill with AI**, Data Profiling, Import, **Export**, Data Generation, Data Masking, Create BI Workspace (os itens sem destaque estão em breve)
  - grid com cabeçalho de duas linhas (nome e tipo: `# int4`, `numeric(5,2)`, `timestamp(6)`), coluna indicadora, célula em foco, `(Null)`, edição, exclusão e inserção pendentes com Apply/Discard em transação
  - rodapé: + − ✓ ✗ ↻ ■, primeira/anterior/página/próxima/última, registros por página (1000 por padrão), buscar no grid, Grid View / **Form View** (textos longos ou com várias linhas, JSON e blobs ganham um campo de várias linhas e o botão que abre o editor de valor)
- **Aba de consulta**: editor com realce, autocomplete, histórico e exportação. **⌘S salva a consulta** na pasta Queries do banco (com nome); ⌘S de novo atualiza.
  - **Run** (⌘↩) roda a seleção ou o editor inteiro; o menu do Run e o menu de contexto do editor têm **Run Selected**, **Run Current Statement** (⌘⇧↩, o comando sob o cursor) e **Run All**. **Beautify SQL** (⌘⇧B) formata localmente.
  - **Explain** mostra o plano do comando selecionado ou sob o cursor sem executá-lo (`EXPLAIN QUERY PLAN` no SQLite, `EXPLAIN (FORMAT JSON)` no PostgreSQL, `EXPLAIN FORMAT=JSON` no MySQL/MariaDB) numa aba **Explain** com a árvore do plano (custo, linhas, condições) e o resultado bruto em Data.
  - **Stop** (⌘.) cancela no servidor: `pg_cancel_backend` e `KILL QUERY` por uma segunda conexão, `sqlite3_interrupt` no SQLite.
  - Cada aba de consulta tem **conexão própria** (aberta na primeira execução, com as Initial Queries, fechada com a aba): uma transação aberta no editor não se mistura com edições aplicadas nas abas de tabela. SQLite em memória continua na conexão do banco.
  - Resultados leem no máximo o limite de Options › Records (1000 por padrão); o rodapé mostra **Load More** e **Fetch All** para consultas de leitura.
  - **Edit Result**: um `SELECT` de uma tabela só (sem JOIN, GROUP BY, DISTINCT, UNION, CTE nem subconsulta no FROM; `ResultEditTarget`) cuja chave primária está no resultado pode ser editado no próprio grid, com o mesmo pipeline da aba de tabela (+ − ✓ ✗ no rodapé, valores como parâmetros tipados, editor de valor, Duplicate, Set to DEFAULT); expressões e colunas renomeadas ficam só leitura. Depois do Apply o comando roda de novo. Fora disso o resultado é só leitura e o botão Edit Result diz por quê. **Data Profiling** do resultado calcula as estatísticas nas linhas lidas, em memória; o **Form View** do resultado usa o mesmo formulário da aba de tabela.
- **Design Table / New Table**: grade de campos (nome, tipo com sugestões do banco, Not Null, chave, Default), abas Fields / Indexes / Foreign Keys / Uniques / Triggers / Options / SQL Preview. Salvar gera `CREATE TABLE` ou `ALTER TABLE` (remover, renomear, mudar tipo/nulo/default, adicionar campo, renomear tabela) e roda numa transação no PostgreSQL e no SQLite; no SQLite, o que o `ALTER TABLE` não faz vira uma reconstrução da tabela. O que o designer não suporta (ex.: trocar a chave primária no PostgreSQL/MySQL) é avisado antes de salvar. Na aba Fields, **Comment** e **Collation** de cada campo no PostgreSQL (`COMMENT ON COLUMN`, `ALTER COLUMN … TYPE … COLLATE`) e no MySQL/MariaDB (no `MODIFY COLUMN`); em Options, o valor de **Auto Increment** (o próximo id: `sqlite_sequence` no SQLite com AUTOINCREMENT, `AUTO_INCREMENT = n` no MySQL); na aba Uniques do SQLite, **ON CONFLICT** de cada unique (escrito como `UNIQUE (…) ON CONFLICT …` no `CREATE TABLE` ou na reconstrução, que agora mantém também o contador do AUTOINCREMENT).
- **Visual do Navicat para macOS**: janela sem barra de título com o título ao lado dos botões da janela, barra de ícones ilustrados (mosaicos com gradiente e selos), controle **View** e avatar; **painel de navegação translúcido** (desfoque do que está atrás da janela, como no Finder); painel direito com abas **ⓘ Info** (cartão da conexão, banco ou tabela) e **AI**; aba Objects com barra de ícones, modo lista/grade e colunas Rows, Data Length, Engine, Created Date e Modified Date; resumo centralizado na barra de status; menu de contexto da conexão (estrela, cor, grupos, executar arquivo SQL…). Ícones são ilustrações SVG próprias (`Sources/BunnyGrid/Resources/Icons`), com gradientes, brilho e sombra, na paleta do Navicat mas sem copiar sua arte; bancos aparecem como cilindros na cor de cada motor, sem logotipos de terceiros. **Ícone do app** no formato do Icon Composer (`Resources/AppIcon.icon`): a arte do coelho branco sobre fundo vermelho numa camada única, para sair exatamente como desenhada; o sistema aplica a máscara e as aparências padrão, escura, tingida e transparente; o `bundle.sh` compila com o `actool` para `Assets.car` mais `AppIcon.icns` de reserva (macOS 14–15). `scripts/preview-icon.sh <pasta>` gera as prévias; `scripts/icon/build-layers.sh` refaz as camadas a partir da arte original. No macOS 26+ a cápsula View, o avatar, o item selecionado, as buscas e o campo do assistente usam Liquid Glass.
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
- **Import Wizard**: importa CSV/TSV, JSON (array de objetos, objeto com um array, JSON Lines; números, booleanos e NULL mantêm o tipo) ou **Excel .xlsx** (leitor próprio: zip com DEFLATE pelo framework Compression, shared strings, texto inline, fórmulas pelo valor guardado, datas pelo formato da célula viram texto ISO, escolha da planilha) numa tabela, com detecção do delimitador, linha de cabeçalho, vazio → NULL, prévia e mapeamento automático por nome, tudo numa transação; ou roda um arquivo .sql no banco.
- **Export Wizard**: várias tabelas e views de uma vez, em CSV (delimitador, cabeçalho), JSON (chaves na ordem das colunas), SQL (CREATE e DROP opcionais, INSERT com N linhas por comando) ou Excel .xlsx (um arquivo por objeto ou uma pasta de trabalho com uma planilha por objeto). O .xlsx é escrito por código próprio (`Sources/BunnyGridCore/Transfer`), sem dependências, com as partes comprimidas em DEFLATE. O menu Export do grid também grava Excel.
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
- **Query Builder** (botão do martelo no editor de consultas), no estilo do Navicat: à esquerda as tabelas e views do banco, arrastadas (ou com duplo clique) para o diagrama; cada tabela é uma caixa com caixas de seleção nas colunas (e `*`), arrastar o título move, arrastar uma coluna até a coluna de outra tabela cria a junção, e as junções por chave estrangeira entram sozinhas. Clicar no selo da linha troca o tipo (Inner, Left, Right, Full Outer; Full desligado no MySQL/MariaDB) ou apaga a junção. Embaixo, as cláusulas em forma de gramática (SELECT com DISTINCT, função de agregação e alias por campo; FROM com aliases; WHERE e HAVING com grupos AND/OR aninhados, NOT, `= <> < <= > >=`, LIKE, IN, BETWEEN, IS NULL e parâmetros `:nome`/`?`; GROUP BY; ORDER BY ASC/DESC; LIMIT/OFFSET) e a prévia do SQL ao lado. O SQL sai no dialeto da conexão (`QueryBuilderSQL`: aspas só quando precisa, `N'…'`, `TOP`, `OFFSET … FETCH`, `LIMIT -1`/`LIMIT 18446744073709551615` para só OFFSET). OK grava no editor sobre a seleção ou o comando sob o cursor (com desfazer); reabrir o builder sobre um SELECT o lê de volta (`QueryBuilderParser`); o que o builder não representa (expressões, funções, subconsultas, UNION, CTE) mostra "can't be shown in the Query Builder" e o OK insere uma consulta nova no cursor. Flag de debug: `--query-builder` (com `--query`).
  - **Opções** (Settings › AI Assistant): por plataforma, Max Tokens, Effort (Low/Medium/High; os modelos atuais não aceitam temperature) e Instruction; Action for Enter key, Enable Compare with Other Assistants e Show AI features.
- **BI** (botão BI da barra principal, File → New BI Workspace, ou Create BI Workspace na barra da tabela): aba de workspace no estilo do Navicat BI, salva em `bi-workspaces.json`. À esquerda, dashboards, gráficos e fontes de dados (tabela/view, consulta salva ou SQL próprio, em qualquer conexão SQL aberta) e a lista de campos da fonte, separada em dimensões e medidas com ícone de tipo (inferido de uma amostra; "Convert to Measure/Dimension" troca). No meio, as prateleiras Axis, Values, Color, Size e Filters recebem campos arrastados (ou por duplo clique / menu); cada pílula escolhe agregação (soma, média, contagem, distintos, mín, máx) ou agrupamento de data (dia, semana, mês, trimestre, ano). À direita, Properties: tipo de gráfico (barras, empilhadas, horizontais, linha, área, pizza, rosca, dispersão, valor/KPI, tabela dinâmica, mapa de calor), fonte, Top N, ordenação, título, legenda, valores, paleta, formato de número e títulos dos eixos. A agregação vai para o banco como GROUP BY (`BIQueryBuilder`, por dialeto, inclusive `TOP` e GROUP BY por expressão no SQL Server); se falhar, as linhas são lidas (até 200 mil) e agregadas em memória (`BIAggregator`). Cada tipo de gráfico tem um teto de pontos e as mudanças são animadas. Dashboards: grade de 12 colunas, arrastar o título move, o canto redimensiona (encaixa na grade e empurra os vizinhos), gráficos entram arrastados da barra lateral ou por Add Chart, e filtros (Add Filter) valem para todos os gráficos cuja fonte tem o campo. Refresh relê tudo; Export grava o gráfico ou dashboard em PNG ou PDF. Flags de debug: `--bi-demo` (workspace de exemplo sobre o demo.sqlite), `--bi-chart N`, `--bi-filter valor,valor`, `--bi-focus`, `--bi-export arquivo.png|pdf`.
- **Model** (barra principal ou "Reverse Database to Model" no menu de contexto do banco/schema): aba com o diagrama ER do banco ou schema, lido do catálogo (tabelas, colunas, chaves primárias e estrangeiras). Layout automático em camadas (tabelas referenciadas à esquerda, relacionadas próximas), arrastar cartões, zoom (⌘+ / ⌘-, pinça, ajustar), clicar destaca as relações; linhas com pés de galinha (1:N, 1:1, opcional). As posições ficam em `model-layouts.json` por conexão, banco e schema. Exporta PNG/PDF e **Generate SQL** gera CREATE TABLE + chaves estrangeiras para SQLite, PostgreSQL, MySQL ou MariaDB (com tradução de tipos), para copiar, salvar ou abrir numa consulta. Flags de debug: `--open-model`, `--model-select TABELA`, `--model-export arquivo.png|pdf`, `--model-sql`.
- **SQL Server e Azure SQL** (cliente TDS 7.4 próprio em Swift sobre SwiftNIO, `Sources/BunnyGridCore/Drivers/TDS`, escrito a partir da especificação pública [MS-TDS]; sem FreeTDS): PRELOGIN, TLS 1.2 dentro de pacotes PRELOGIN (como o TDS 7.x exige) e depois na conexão inteira, LOGIN7 com SQL Server Authentication, SQLBatch, RPC `sp_executesql` com parâmetros tipados (`@p1…`, bigint/float/bit/varbinary/nvarchar), ATTENTION. Tipos: int/bigint/smallint/tinyint, bit, decimal/numeric, money/smallmoney, float/real, char/varchar/nchar/nvarchar (inclusive `max`, por PLP), text/ntext/image, binary/varbinary, date/time/datetime/datetime2/datetimeoffset/smalldatetime, uniqueidentifier, xml, sql_variant e tipos CLR (como bytes); varchar decodificado pela página de código da collation (e UTF-8 nas collations `_UTF8`).
  - **New Connection**: SQL Server, Azure SQL Database e os serviços SQL Server de AWS, Google Cloud, Alibaba, Huawei e Tencent funcionam (porta 1433). Authentication mostra só SQL Server Authentication (Windows/Entra ainda não). SSL: Disabled não pede criptografia (o servidor pode exigir), Prefer usa TLS quando o servidor oferece, Require exige sem checar o certificado, Verify CA / Verify Full checam a CA e o nome. Túnel SSH pelo mesmo `ConnectionEndpoint`; SQL Server não aceita socket Unix. `sqlserver://` e `mssql://` no New Connection with URI (`?encrypt=true|false|strict`).
  - **Navegação** como no Navicat for SQL Server: conexão → bancos → schemas (`dbo` aberto) → Tables / Views / Functions (procedures e funções) / Queries / Backups; cada banco tem a sua conexão.
  - Catálogo `sys.*`: colunas (tipos como `nvarchar(50)`, `decimal(10,2)`), índices, chaves estrangeiras, triggers, estatísticas (linhas, tamanho, MS_Description, datas) e DDL montado como o SSMS (IDENTITY, colunas computadas, defaults nomeados, PK/UNIQUE CLUSTERED/NONCLUSTERED, CHECK, índices com INCLUDE e filtro, triggers, chaves no fim); views, procedures e funções mostram `OBJECT_DEFINITION`.
  - Grid paginado com `OFFSET … FETCH`, edições como parâmetros tipados (NULL vai literal), transações (`BEGIN TRANSACTION`, o descritor acompanha o ENVCHANGE), Design Table (`sp_rename`, `ALTER COLUMN`, defaults como constraints), renomear/duplicar/truncar, Dump SQL (com `SET IDENTITY_INSERT`), Explain pelo `SET SHOWPLAN_XML` (árvore de operadores com custo e linhas), Stop pelo ATTENTION na própria conexão, limite de linhas que para o servidor (ATTENTION) em vez de descartar, logins no User (sysadmin/dbcreator), Others (procedures, triggers, sequences, synonyms, types, índices, schemas). O divisor de scripts entende `GO`, `[identificadores]` e os `BEGIN … END` de procedures e funções.
- **MongoDB** (cliente próprio em Swift sobre SwiftNIO, sem dependências novas): BSON completo (inclusive Decimal128), OP_MSG, `hello`, SCRAM-SHA-256 e SCRAM-SHA-1, TLS pela aba SSL, túnel SSH e socket pelo mesmo `ConnectionEndpoint`, `mongodb://` com vários hosts (conecta no primário do replica set) e `mongodb+srv://` (registros SRV/TXT via dnssd, TLS ligado). New Connection com MongoDB e MongoDB Atlas; o formulário ganha Connection Type (Standalone/Replica Set ou SRV), outros hosts, Replica Set, Auth Database e Auth Mechanism, e New Connection with URI aceita `mongodb://` e `mongodb+srv://`.
  - **Navegação**: conexão → bancos → Collections / Views / GridFS / Indexes / Queries. O driver implementa `DatabaseDriver` (coleções como tabelas com a união das chaves de primeiro nível, aninhados como JSON) e `DocumentDatabaseDriver` (find, aggregate, insert, update, delete, runCommand, explain, índices, `$collStats`). Os drivers SQL não mudaram.
  - **Visualizador de coleção**: Grid View (cabeçalho com o tipo BSON de cada campo), Tree View e JSON View; barra Filter / Sort / Projection com a sintaxe do shell; paginação com o total; clicar no cabeçalho ordena; edições de célula pendentes com Apply/Discard (`$set` por `_id`, preservando o tipo do campo); Add / Edit / Duplicate / Delete abrem um editor JSON com Beautify e Validate (`ObjectId("…")`, `ISODate("…")`, `NumberLong`…); Import (JSON, JSON Lines, CSV) e Export (JSON em Extended JSON relaxado, JSON Lines, CSV); estatísticas (documentos, tamanho, índices); GridFS: Save File remonta o arquivo dos chunks.
  - **Shell** (New Query numa conexão MongoDB): `db.coll.find({…}).sort({…}).skip(n).limit(n)`, `findOne`, `aggregate([…])`, `countDocuments`, `estimatedDocumentCount`, `distinct`, `insertOne/Many`, `updateOne/Many`, `replaceOne`, `deleteOne/Many`, `createIndex`, `dropIndex`, `getIndexes`, `drop`, `stats`, `renameCollection`, `db.runCommand`, `db.adminCommand`, `db.createCollection`, `db.createView`, `show dbs|collections|users`, `use`, `db.getSiblingDB(…)`, `db.getCollection(…)`. O parser aceita chaves sem aspas, aspas simples, vírgula final, comentários, regex `/…/i`, `ObjectId`, `ISODate`, `new Date`, `NumberLong`, `NumberInt`, `NumberDecimal`, `Timestamp`, `BinData`, `UUID`, `MinKey/MaxKey` e Extended JSON. Um resultado por comando, em Grid/Tree/JSON; **Explain** mostra a árvore do plano vencedor (COLLSCAN, IXSCAN, FETCH… com nReturned e documentos examinados); **Stop** acha a operação pelo `comment` e roda `killOp` por uma segunda conexão.
- **Backup** (botão Backup da barra principal, pasta Backups da aba Objects ou Tools › New Backup…): backup do banco ou schema com comentário, escolha de objetos, estrutura e/ou dados; no SQLite também cópia do arquivo inteiro pela API `sqlite3_backup`. A lista mostra data, tamanho, objetos, linhas, tipo e comentário; **Restore** no mesmo banco ou em outro banco aberto do mesmo motor (Drop existing, Continue on error, transação única, com progresso e erros), **Extract SQL** para um .sql, editar comentário, mostrar no Finder, apagar (vai para o Lixo).
  - Formato `.bgbackup` (versão 1): `BGBACKUP` + versão (UInt32 LE) + tamanho do manifesto (UInt32 LE) + manifesto JSON (conexão, banco, schema, data, comentário, objetos, linhas) + o script SQL (ou o arquivo SQLite) comprimido em DEFLATE puro (`COMPRESSION_ZLIB` da Apple; `zlib.decompress(dados, -15)` no Python). O script vem do Dump SQL, com DROP … IF EXISTS e INSERTs de 100 linhas.
- **Automation** (botão Automation, Tools › Automation ⇧⌘J): janela com os batch jobs. Cada job tem passos em ordem (Run Saved Query, Run SQL, Execute SQL File, Backup, Export com as opções do Export Wizard e pasta de saída, opcionalmente datada, Data Transfer entre duas conexões), "continuar quando um passo falha", agendamento (manual, uma vez, de hora em hora, diário, semanal, mensal ou cron de 5 campos com as próximas 5 execuções), notificações de sucesso e falha, e o histórico com status, duração e log de cada execução. Start roda na hora, dentro do app.
  - Agendamentos rodam com o app fechado: salvar um agendamento ativo grava `~/Library/LaunchAgents/app.bunnygrid.job.<id>.plist` (`StartCalendarInterval`) e carrega com `launchctl bootstrap`; desligar o agendamento ou apagar o job faz `bootout` e remove o plist. O launchd executa `BunnyGrid --run-job <id> --scheduled`, modo headless do mesmo executável: lê conexões, consultas e jobs da pasta de dados, as senhas do Keychain, conecta pelo mesmo caminho (SSH, SSL, socket, Initial Queries), grava a execução e notifica. `SMAppService.agent` não foi usado porque só registra plists fixos dentro do bundle, sem horário por job.
  - Para testar sem tocar em `~/Library/LaunchAgents`: `BUNNYGRID_LAUNCH_AGENTS_DIR=<pasta>` grava os plists ali e não chama o launchctl. Rodar um job à mão: `BUNNYGRID_DATA_DIR=<pasta> build/BunnyGrid.app/Contents/MacOS/BunnyGrid --run-job <id>` (saída 0 = sucesso, 1 = falhou, 2 = job não encontrado). Flag de debug: `-automationPane steps|schedule|history`.
- **Menus**: File, View (painéis), Table, Favorites (em breve), Tools.
- **Redis** (como o Navicat for Redis): conexão → db0…db15 com o número de chaves (`INFO keyspace`) → chaves agrupadas em pastas pelo separador (`:` por padrão; menu do banco › Key Separator), carregadas aos poucos com `SCAN` (nunca `KEYS`) e Load More Keys. Filtro por padrão `MATCH` e por tipo acima da busca. Visualizador por tipo: string em texto, JSON (Beautify/Minify/validação) ou hex, carregar e salvar arquivo; hash, list, set, sorted set e stream em tabela com adicionar, editar (inclusive score), remover e filtrar; JSON do RedisJSON; TTL (EXPIRE/PERSIST), renomear (`RENAMENX`) e excluir; tamanho e `MEMORY USAGE` no rodapé. **New Key** para os sete tipos, com TTL. **Console** com conexão própria, prompt com o banco, histórico (↑/↓), respostas coloridas no formato do redis-cli e várias linhas de uma vez. **Server Monitor** com versão, uptime, clientes, memória, ops/s e hit rate, todas as seções do INFO, CLIENT LIST e SLOWLOG, com atualização automática. Conecta com senha ou usuário ACL (`HELLO 3`, com volta ao RESP2 e `AUTH` em servidores antigos), SSL (Require/Verify, CA e certificado de cliente), socket Unix, túnel SSH e URI `redis://` / `rediss://`. Serviços na nuvem compatíveis com Redis (ElastiCache, Memorystore, Azure Cache, Garnet, Redis Enterprise Cloud, ApsaraDB, DCS, TencentDB) usam o mesmo driver. Flags de debug (com `--connect-first` numa conexão Redis): `--redis-expand db0,user:`, `--redis-key CHAVE`, `--redis-console [COMANDOS]`, `--redis-server`, `--redis-new-key`.

## Licenças

- **Beekeeper Studio Community** é GPL-3 (e `src-commercial/` tem licença comercial). Copiar ou traduzir o código dele para Swift faz do BunnyGrid uma obra derivada sob GPL-3. Até que se decida isso, o Beekeeper serve só como referência de arquitetura e comportamento.
- Dependências atuais: PostgresNIO e MySQLNIO (MIT), SwiftNIO (Apache-2.0), SQLite do sistema. O cliente Redis é código próprio sobre SwiftNIO (o RediStack não foi usado: só fala RESP2). O MongoDB não usa o MongoKitten: o cliente é próprio (BSON + OP_MSG + SCRAM, ~2 mil linhas), sem pacotes novos, testado contra o MongoDB 9.0 (wire version 29). O SQL Server também usa um cliente próprio (TDS 7.4 sobre SwiftNIO; só acrescenta o produto NIOTLS do swift-nio), testado contra o SQL Server 2022 (16.0).
