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
| 0.8 | Próximos | Table Profile (filtros salvos), Export Wizard (vários objetos), túnel SSH, testes de integração com MySQL | Navicat |
| 0.3 | Editor SQL | Consultas salvas, formatação, executar o comando sob o cursor, EXPLAIN | Navicat "Query Editor" |
| 0.3 | Edição | Editor de valor para textos longos, JSON e blobs (inline só aceita uma linha), duplicar linha | Navicat "Cell Editors" |
| 0.3 | Conectividade | Túnel SSH (Citadel, puro Swift), SSL com verificação e certificados de cliente, socket Unix | `tunnel.ts` |
| ✅ 0.3 | Estrutura | Designer de tabela (ALTER), índices, chaves estrangeiras, DDL (`getTableCreateScript`) | `alterTableSql` |
| 0.4 | Import/Export | CSV, JSON, SQL dump, Excel (libxlsxwriter, BSD) | Navicat Import/Export Wizard |
| 0.5 | Mais bancos | SQL Server (FreeTDS), Redis (RediStack), MongoDB (MongoKitten) | Navicat §2 |
| 0.6 | Transferência | Data Transfer entre bancos, comparação e sincronização de estrutura e de dados | Navicat Structure/Data Sync |
| ✅ 0.7 | Modelagem | Diagrama ER (engenharia reversa), modelo → SQL | Navicat Modeling |
| 0.8 | Automação | Jobs agendados (SMAppService + launchd), backup | Navicat Automation |
| depois | BI e IA | Gráficos com Swift Charts, perfil de dados, assistente de SQL com a Claude API | Navicat BI / AI Assistant |

## Débitos técnicos conhecidos

- O AI Assistant não foi testado contra a API real nesta máquina (sem chave); o protocolo está coberto por testes unitários.
- Automation, BI e Create BI Workspace aparecem na interface, mas ainda mostram "em breve". Model já funciona (diagrama ER, layout salvo, PNG/PDF e Generate SQL); falta sincronizar modelo → banco e editar o modelo (só leitura, por enquanto), e as linhas que pulam uma camada podem cruzar cartões no meio. User (PostgreSQL/MySQL), Others, Export Wizard, Dump SQL e as ações de tabela (excluir, esvaziar, truncar, renomear, duplicar) já funcionam.

- Edições aplicadas enquanto outra consulta roda na mesma conexão entram na mesma transação (há uma conexão por sessão). Separar uma conexão para o editor resolve.
- Valores editados são enviados como texto (`'42'`) e o banco converte para o tipo da coluna. Funciona em PostgreSQL, MySQL e SQLite, mas tipos exóticos podem precisar de cast.
- Cancelar uma consulta só cancela a tarefa local; falta enviar o cancelamento ao servidor (`pg_cancel_backend` / `KILL QUERY`).
- O realce de sintaxe refaz o documento inteiro a cada tecla; trocar por tree-sitter (CodeEditSourceEditor) quando os scripts ficarem grandes.
- Resultados são carregados inteiros na memória; falta paginação ou streaming no editor SQL.
- O driver MySQL/MariaDB ainda não tem testes de integração (o PostgreSQL tem: `BUNNYGRID_PG_PORT`); a leitura e o ALTER de chaves estrangeiras no MySQL só têm testes de geração de SQL.
- Trocar a chave primária pelo designer só funciona no SQLite (reconstrução); no PostgreSQL e no MySQL ainda é recusado.
- A reconstrução de tabela do SQLite recusa CHECK, COLLATE, colunas geradas, WITHOUT ROWID, STRICT, ON CONFLICT e chaves DEFERRABLE (o designer não modela essas definições), e o contador de AUTOINCREMENT recomeça do maior id copiado. Os nomes de chaves estrangeiras do SQLite não aparecem (o `PRAGMA foreign_key_list` não os informa).
- Renomear um campo usado numa chave estrangeira não atualiza a linha da aba Foreign Keys (o banco renomeia a referência; no SQLite a reconstrução também).
- Builds de desenvolvimento são assinados ad hoc: a cada rebuild o macOS pode pedir de novo acesso às senhas no Keychain. Com assinatura Developer ID isso não acontece.
