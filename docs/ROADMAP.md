# Roadmap

As fases seguem o mapa de funções do Navicat (`Clones/Navicat Premium/SPEC.md`, §3 e §6), usando o Beekeeper Studio (`Clones/beekeeper-studio/apps/studio/src/lib/db`) como referência de arquitetura.

| Fase | Área | Escopo | Referência |
|---|---|---|---|
| ✅ 0.1 | Base | Conexões + Keychain, drivers SQLite/PostgreSQL/MySQL, árvore, grid paginado, editor SQL | `BasicDatabaseClient.ts`, `models.ts` |
| ✅ 0.2 | Edição de dados | Editar célula, inserir e excluir linhas, aplicar ou descartar alterações em transação (precisa de chave primária) | `applyChanges`, `TableChanges` |
| ✅ 0.2 | Editor SQL | Histórico, autocomplete de tabelas, colunas e aliases, resultados parciais em erro | Navicat "Query Editor" |
| ✅ 0.2 | Exportação | CSV e JSON de resultados e páginas | Navicat Export Wizard |
| ✅ 0.3 | Interface | Layout do Navicat: barra principal, navegação por conexão → banco → schema → pasta, aba Objects, grid de duas linhas, Form View, Cell Editor, barra de status | Navicat (SPEC §3) |
| ✅ 0.3 | IA | AI Assistant com a API do Claude, contexto de tabela/schema, Fill with AI | Navicat AI Assistant |
| ✅ 0.4 | Estrutura e dados | Design/New Table, Import Wizard (CSV), consultas salvas (pasta Queries), Favorites, ⌘S unificado | Navicat |
| ✅ 0.5 | Dados e estrutura | Begin Transaction (conexão própria por aba), Data Generation, índices no designer, testes de integração com PostgreSQL | Navicat |
| ✅ 0.6 | Design e experiência | Tema claro, grid e navegação no visual do Navicat, Table Profile, Data Profiling, Data Masking, estatísticas na aba Objects, abas persistentes, teclado no grid e na árvore | Navicat |
| ✅ 0.7 | Visual macOS | Layout do Navicat para macOS: chrome unificado, ícones ilustrados, sidebar translúcida, painel Info/AI, aba Objects com ícones e modo grade, menu de contexto da conexão | Navicat macOS |
| ✅ 0.8 | Estrutura | Chaves estrangeiras no designer (aba Foreign Keys; ALTER no PostgreSQL/MySQL, reconstrução da tabela no SQLite), DDL do PostgreSQL montado do catálogo, Dump SQL com as chaves no fim | Navicat Design Table |
| ✅ 0.8 | Import/Export | Export Wizard com vários objetos em CSV, JSON, SQL (CREATE/DROP opcionais, INSERT em lotes) e Excel .xlsx (writer próprio em Swift, zip STORE + CRC32); Import Wizard com CSV, JSON (array, objeto com array, JSON Lines) e arquivo .sql; Execute SQL File com progresso, parar no erro e transação única; `DELIMITER` do mysqldump; Table Profile padrão ao abrir a tabela; testes de integração com MySQL/MariaDB (`BUNNYGRID_MYSQL_PORT`) | Navicat Import/Export Wizard |
| ✅ 0.8 | Editor SQL | Consultas salvas, formatação (⌘⇧B), Run Selected / Run Current Statement (⌘⇧↩) / Run All, Explain com árvore do plano, Stop cancelando no servidor, conexão própria por aba de consulta, resultados limitados com Load More / Fetch All | Navicat "Query Editor" |
| ✅ 0.8 | Edição | Editor de valor pelo tipo da coluna (texto multilinha, JSON com Beautify/Minify/validação, hex e imagem para blobs com carregar/salvar arquivo, calendário e hora), em popover (⌥↩, duplo clique em valores longos) e no painel Cell Editor; NULL / vazio / DEFAULT; duplicar registros; Copy As (INSERT, UPDATE, TSV, CSV, JSON, Markdown); valores enviados como parâmetros tipados | Navicat "Cell Editors" |
| ✅ 0.8 | Conectividade | Abas SSL e SSH do Navicat: túnel SSH (Citadel, puro Swift) com senha ou chave (ed25519, ECDSA; RSA só onde o servidor aceita `ssh-rsa`), host key por confiança no primeiro uso (`ssh-known-hosts.json`) e túnel compartilhado pelas conexões da sessão; SSL Prefer / Require / Verify CA / Verify Full com CA e certificado de cliente (PostgreSQL e MySQL); socket Unix (aba Advanced); Test Connection pelo mesmo caminho; senha SSH, passphrase da chave e do certificado só no Keychain | `tunnel.ts` |
| ✅ 0.3 | Estrutura | Designer de tabela (ALTER), índices, chaves estrangeiras, DDL (`getTableCreateScript`) | `alterTableSql` |
| 0.9 | Import/Export | Importar Excel (.xlsx) e XML, exportar XML/HTML/Markdown, agendar exportações, streaming para tabelas grandes | Navicat Import/Export Wizard |
| 0.5 | Mais bancos | SQL Server (FreeTDS), Redis (RediStack), MongoDB (MongoKitten) | Navicat §2 |
| ✅ 0.9 | Transferência | Data Transfer entre SQLite/PostgreSQL/MySQL (ou para .sql) com tradução de tipos, lotes tipados, progresso e Stop; Structure Synchronization (diff + script de deploy); Data Synchronization (inserções/atualizações/exclusões em transação) | Navicat Structure/Data Sync |
| ✅ 0.7 | Modelagem | Diagrama ER (engenharia reversa), modelo → SQL | Navicat Modeling |
| 0.8 | Automação | Jobs agendados (SMAppService + launchd), backup | Navicat Automation |
| depois | BI e IA | Gráficos com Swift Charts, perfil de dados, assistente de SQL com a Claude API | Navicat BI / AI Assistant |

## Débitos técnicos conhecidos

- O AI Assistant não foi testado contra a API real nesta máquina (sem chave); o protocolo está coberto por testes unitários.
- Automation, BI e Create BI Workspace aparecem na interface, mas ainda mostram "em breve". Model já funciona (diagrama ER, layout salvo, PNG/PDF e Generate SQL); falta sincronizar modelo → banco e editar o modelo (só leitura, por enquanto), e as linhas que pulam uma camada podem cruzar cartões no meio. User (PostgreSQL/MySQL), Others, Export Wizard, Dump SQL e as ações de tabela (excluir, esvaziar, truncar, renomear, duplicar) já funcionam.

- Edições vão como parâmetros tipados escolhidos pelo tipo da coluna (inteiro, double, booleano, bytes, data/hora, NULL). Tipos que o app não modela (numeric, arrays, enums, geometria, intervalos) seguem como texto sem tipo declarado e o banco converte, como faria com um literal. O binding do MySQL/MariaDB ainda não tem teste de integração (o do SQLite e o do PostgreSQL têm).
- No PostgreSQL, uma linha cuja chave primária é um `timestamp` com frações de segundo não pode ser editada: o valor chega ao grid sem as frações e o WHERE não acha a linha.
- O realce de sintaxe refaz o documento inteiro a cada tecla; trocar por tree-sitter (CodeEditSourceEditor) quando os scripts ficarem grandes.
- O editor SQL lê no máximo o limite de registros por resultado, mas Load More e Fetch All executam a consulta de novo (não há cursor aberto no servidor). No MySQL as linhas além do limite ainda trafegam e são descartadas (o MySQLNIO não tem backpressure); no PostgreSQL o PostgresNIO descarta o restante do stream.
- O Stop no PostgreSQL e no MySQL abre uma conexão curta para cancelar (o PostgresNIO não expõe o CancelRequest do protocolo); se o comando terminar antes e uma nova execução começar nesse intervalo, é ela que recebe o cancelamento.
- Os testes de integração do MySQL/MariaDB (`BUNNYGRID_MYSQL_PORT`, `Tests/BunnyGridCoreTests/MySQLIntegrationTests.swift`) ainda não rodaram contra um servidor real: nesta máquina não há MySQL, MariaDB nem Docker. Os do PostgreSQL rodam (servidor descartável do Homebrew numa porta própria). A leitura e o ALTER de chaves estrangeiras no MySQL só têm testes de geração de SQL.
- MySQL: um SELECT sem linhas volta sem nomes de colunas (o MySQLNIO só entrega as definições junto com as linhas). Comandos que o protocolo de prepared statements recusa (`LOCK TABLES`, `CREATE PROCEDURE/TRIGGER`, …) caem no protocolo de texto, que não informa linhas afetadas.
- Exportação e importação carregam a tabela ou o arquivo inteiros na memória; o .xlsx é gravado sem compressão (zip STORE), então fica maior que o do Excel.
- Dump SQL do PostgreSQL recria as sequências de colunas `serial`, mas não colunas `GENERATED … AS IDENTITY`, tipos, extensões nem funções.
- Trocar a chave primária pelo designer só funciona no SQLite (reconstrução); no PostgreSQL e no MySQL ainda é recusado.
- A reconstrução de tabela do SQLite recusa CHECK, COLLATE, colunas geradas, WITHOUT ROWID, STRICT, ON CONFLICT e chaves DEFERRABLE (o designer não modela essas definições), e o contador de AUTOINCREMENT recomeça do maior id copiado. Os nomes de chaves estrangeiras do SQLite não aparecem (o `PRAGMA foreign_key_list` não os informa).
- Renomear um campo usado numa chave estrangeira não atualiza a linha da aba Foreign Keys (o banco renomeia a referência; no SQLite a reconstrução também).
- Túnel SSH: o Citadel assina chaves RSA com SHA-1 (`ssh-rsa`), que o OpenSSH 8.8+ recusa por padrão; o app mostra o motivo e sugere ed25519/ECDSA. Chaves ECDSA em formato OpenSSH só sem passphrase; chaves PEM criptografadas não são lidas. Login por senha não foi testado contra um servidor real (o sshd de teste roda sem root, só com chave). Sem keyboard-interactive, jump host nem agente SSH.
- A host key desconhecida é aceita e gravada sem perguntar (TOFU); o fingerprint aparece na aba SSH e no Test Connection, e uma chave diferente bloqueia a conexão até "Forget Host Key". Falta um diálogo de confirmação na primeira conexão.
- Quando a sessão SSH cai, as conexões abertas por ela falham; o próximo connect abre outro túnel, mas não há reconexão automática.
- SSL (modos Verify, certificado de cliente), socket e túnel SSH do MySQL usam o mesmo caminho do PostgreSQL e têm casos em `MySQLIntegrationTests` (`BUNNYGRID_MYSQL_SSL_CA`, `BUNNYGRID_MYSQL_SOCKET`, `BUNNYGRID_SSH_*`), mas ainda não rodaram contra um servidor real.
- Builds de desenvolvimento são assinados ad hoc: a cada rebuild o macOS pode pedir de novo acesso às senhas no Keychain. Com assinatura Developer ID isso não acontece.
- Transferência e sincronização: o Data Sync lê as duas tabelas inteiras e o Data Transfer pagina com OFFSET; falta cursor no servidor para tabelas grandes. Views só são comparadas entre motores iguais; CHECK, triggers, sequências, funções e comentários não entram no diff. Os testes do MySQL (`SyncIntegrationTests.swift`) ainda não rodaram contra um servidor real; os do PostgreSQL rodam.
