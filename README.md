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

No build de debug: `--demo-edits` (com `--open-table`) cria alterações pendentes de exemplo, `--focus-cell` foca uma célula, `--show-objects` abre a aba Objects com a pasta Tables selecionada, `--design TABELA` abre o Design Table, `--new-table` abre o New Table, `--connect-first` abre a primeira conexão salva, `--begin-transaction` e `--generate` (com `--open-table`) abrem o modo de transação e a Data Generation.

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
```

Dados do usuário:
- conexões: `~/Library/Application Support/BunnyGrid/connections.json`
- histórico: `~/Library/Application Support/BunnyGrid/history.json`
- consultas salvas e favoritos: `~/Library/Application Support/BunnyGrid/queries.json` e `favorites.json`
- conversas do AI Assistant: `~/Library/Application Support/BunnyGrid/ai-chats.json`
- chave da API do Claude: Keychain, serviço `app.bunnygrid.anthropic`
- senhas: Keychain, serviço `app.bunnygrid.connections`

## O que já funciona (v0.7)

A janela segue o layout do Navicat Premium (ícones próprios em SF Symbols; nada da arte do Navicat é usado):

- **Barra principal**: Connection (menu de tipos), New Query, Table, View, Materialized View, Function, Role, Others, Query, Backup, Automation, Model, BI, Sobre, AI Assistant e conta. Os botões de tipo de objeto mostram aquela categoria na aba Objects. Role, Others, Automation, Model e BI estão desativados ("em breve").
- **Painel de navegação**: BunnyGrid Cloud (em breve) → My Connections → grupos (pastas) → conexões → bancos → schemas (PostgreSQL) → Tables / Views / Materialized Views / Functions / Queries / Backups → objetos. Abrir um nó conecta ou abre o banco; no PostgreSQL cada banco tem sua própria conexão. No rodapé: busca, localizar o objeto da aba aberta e recolher tudo.
- **Abas**: "Objects" fixa e abas como `payment @dvdrental.public (PostgreSQL)`. O título da janela segue o Navicat (`… - Table - BunnyGrid`).
- **Aba Objects**: Open / Design / New / Delete, Import / Export Wizard e busca; lista os objetos da pasta selecionada ou os bancos da conexão.
- **Aba de tabela**
  - barra: Table Profile, Begin Transaction, **Cell Editor**, **Filter & Sort**, **Columns** (mostrar/ocultar), **History** (SQL executado pela aba), **Fill with AI**, Data Profiling, Import, **Export**, Data Generation, Data Masking, Create BI Workspace (os itens sem destaque estão em breve)
  - grid com cabeçalho de duas linhas (nome e tipo: `# int4`, `numeric(5,2)`, `timestamp(6)`), coluna indicadora, célula em foco, `(Null)`, edição, exclusão e inserção pendentes com Apply/Discard em transação
  - rodapé: + − ✓ ✗ ↻ ■, primeira/anterior/página/próxima/última, registros por página (1000 por padrão), buscar no grid, Grid View / **Form View**
- **Aba de consulta**: editor com realce, autocomplete, histórico e exportação. **⌘S salva a consulta** na pasta Queries do banco (com nome); ⌘S de novo atualiza.
- **Design Table / New Table**: grade de campos (nome, tipo com sugestões do banco, Not Null, chave, Default), abas Fields / Indexes / SQL Preview. Salvar gera `CREATE TABLE` ou `ALTER TABLE` (remover, renomear, mudar tipo/nulo/default, adicionar campo, renomear tabela) e roda numa transação no PostgreSQL e no SQLite. O que o banco não suporta (ex.: mudar tipo no SQLite, trocar a chave primária) é avisado antes de salvar.
- **Visual do Navicat para macOS**: janela sem barra de título com o título ao lado dos botões da janela, barra de ícones ilustrados (mosaicos com gradiente e selos), controle **View** e avatar; **painel de navegação translúcido** (desfoque do que está atrás da janela, como no Finder); painel direito com abas **ⓘ Info** (cartão da conexão, banco ou tabela) e **AI**; aba Objects com barra de ícones, modo lista/grade e colunas Rows, Data Length, Engine, Created Date e Modified Date; resumo centralizado na barra de status; menu de contexto da conexão (estrela, cor, grupos, executar arquivo SQL…). Ícones são ilustrações SVG próprias (`Sources/BunnyGrid/Resources/Icons`), com gradientes, brilho e sombra, na paleta do Navicat mas sem copiar sua arte; bancos aparecem como cilindros na cor de cada motor, sem logotipos de terceiros. No macOS 26+ a cápsula View, o avatar, o item selecionado, as buscas e o campo do assistente usam Liquid Glass.
- **Aparência** (Settings → General): Sistema, Claro ou Escuro. O tema claro é o do modelo do Navicat.
- **Table Profile ▾**: salva e reaplica filtro, ordenação, colunas ocultas e máscaras de uma tabela.
- **Data Profiling**: por coluna, registros, nulos (com medidor de preenchimento), distintos, mínimo, máximo, média e os valores mais frequentes em barras.
- **Data Masking**: mascara colunas no grid e nas exportações (total, parcial, e-mail, últimos 4 dígitos); colunas mascaradas não são editáveis e o banco não é alterado.
- **Aba Objects** com Rows, Data Length, Engine (MySQL) e Comment.
- **Fluidez**: abas mantêm rolagem, seleção e texto ao alternar; ← → movem a célula em foco, Return ou digitar começa a editar; duplo clique na divisória do cabeçalho ajusta a coluna; Return / ← / → na árvore abrem, recolhem e expandem com animação; ⌘W fecha a aba, ⌃Tab / ⌃⇧Tab trocam de aba; os painéis lembram se estavam abertos.
- **Begin Transaction** (aba de tabela): abre uma conexão só da aba e executa `BEGIN`; as edições aplicadas ficam invisíveis para outras conexões até **Commit** (que aplica antes as edições pendentes) ou **Rollback**. Fechar a aba desfaz a transação.
- **Data Generation**: gera registros realistas (nomes, e-mails, telefones, cidades, empresas, UUIDs, datas, números, textos…), com o gerador sugerido pelo nome e tipo de cada campo, chaves automáticas puladas, respeito a `numeric(p,s)`, `smallint` e `varchar(n)`, prévia reproduzível e inserção numa transação.
- **Índices no Design Table**: criar, renomear, mudar campos/unicidade e remover índices (a chave primária fica protegida).
- **Import Wizard**: importa CSV/TSV numa tabela, com detecção do delimitador, linha de cabeçalho, vazio → NULL, prévia e mapeamento automático por nome; tudo numa transação.
- **Favorites**: favoritar tabelas/views (menu de contexto ou ⌘D), menu Favorites para abrir, e a estrela no rodapé do painel de navegação mostra só os favoritos.
- **⌘S** salva o que a aba atual tiver: edições do grid, consulta ou design.
- **Barra de status**: SQL da aba, alerta, "Record 5 of 1000 in page 1", "Last Refresh", e botões para mostrar/ocultar os painéis.
- **AI Assistant** (painel direito): conversas salvas, nova conversa, chips de contexto (tabela aberta e schema), anexar arquivo de texto, escolha do modelo (padrão `claude-opus-5-5`), respostas em streaming com blocos SQL que abrem no editor. A chave da API fica no Keychain (**Settings**, ⌘,) ou vem de `ANTHROPIC_API_KEY`. Recusas usam o fallback do servidor (`fallbacks: "default"`) e são avisadas na conversa.
- **Menus**: File, View (painéis), Table, Favorites (em breve), Tools.

## Licenças

- **Beekeeper Studio Community** é GPL-3 (e `src-commercial/` tem licença comercial). Copiar ou traduzir o código dele para Swift faz do BunnyGrid uma obra derivada sob GPL-3. Até que se decida isso, o Beekeeper serve só como referência de arquitetura e comportamento.
- Dependências atuais: PostgresNIO e MySQLNIO (MIT), SwiftNIO (Apache-2.0), SQLite do sistema.
