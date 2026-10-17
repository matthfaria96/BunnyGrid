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
| 0.8 | Próximos | Chaves estrangeiras no designer, Table Profile (filtros salvos), Export Wizard (vários objetos), testes de integração com MySQL | Navicat |
| 0.3 | Editor SQL | Consultas salvas, formatação, executar o comando sob o cursor, EXPLAIN | Navicat "Query Editor" |
| 0.3 | Edição | Editor de valor para textos longos, JSON e blobs (inline só aceita uma linha), duplicar linha | Navicat "Cell Editors" |
| ✅ 0.8 | Conectividade | Abas SSL e SSH do Navicat: túnel SSH (Citadel, puro Swift) com senha ou chave (ed25519, ECDSA; RSA só onde o servidor aceita `ssh-rsa`), host key por confiança no primeiro uso (`ssh-known-hosts.json`) e túnel compartilhado pelas conexões da sessão; SSL Prefer / Require / Verify CA / Verify Full com CA e certificado de cliente (PostgreSQL e MySQL); socket Unix (aba Advanced); Test Connection pelo mesmo caminho; senha SSH, passphrase da chave e do certificado só no Keychain | `tunnel.ts` |
| 0.3 | Estrutura | Designer de tabela (ALTER), índices, chaves estrangeiras, DDL (`getTableCreateScript`) | `alterTableSql` |
| 0.4 | Import/Export | CSV, JSON, SQL dump, Excel (libxlsxwriter, BSD) | Navicat Import/Export Wizard |
| 0.5 | Mais bancos | SQL Server (FreeTDS), Redis (RediStack), MongoDB (MongoKitten) | Navicat §2 |
| 0.6 | Transferência | Data Transfer entre bancos, comparação e sincronização de estrutura e de dados | Navicat Structure/Data Sync |
| 0.7 | Modelagem | Diagrama ER (engenharia reversa), modelo → SQL | Navicat Modeling |
| 0.8 | Automação | Jobs agendados (SMAppService + launchd), backup | Navicat Automation |
| depois | BI e IA | Gráficos com Swift Charts, perfil de dados, assistente de SQL com a Claude API | Navicat BI / AI Assistant |

## Débitos técnicos conhecidos

- O AI Assistant não foi testado contra a API real nesta máquina (sem chave); o protocolo está coberto por testes unitários.
- Automation, Model, BI e Create BI Workspace aparecem na interface, mas ainda mostram "em breve". User (PostgreSQL/MySQL), Others, Export Wizard, Dump SQL e as ações de tabela (excluir, esvaziar, truncar, renomear, duplicar) já funcionam.

- Edições aplicadas enquanto outra consulta roda na mesma conexão entram na mesma transação (há uma conexão por sessão). Separar uma conexão para o editor resolve.
- Valores editados são enviados como texto (`'42'`) e o banco converte para o tipo da coluna. Funciona em PostgreSQL, MySQL e SQLite, mas tipos exóticos podem precisar de cast.
- Cancelar uma consulta só cancela a tarefa local; falta enviar o cancelamento ao servidor (`pg_cancel_backend` / `KILL QUERY`).
- O realce de sintaxe refaz o documento inteiro a cada tecla; trocar por tree-sitter (CodeEditSourceEditor) quando os scripts ficarem grandes.
- Resultados são carregados inteiros na memória; falta paginação ou streaming no editor SQL.
- O driver MySQL/MariaDB ainda não tem testes de integração (o PostgreSQL tem: `BUNNYGRID_PG_PORT`). SSL, certificado de cliente e socket do MySQL foram escritos como no PostgreSQL, mas só o PostgreSQL foi testado contra um servidor real.
- Túnel SSH: o Citadel assina chaves RSA com SHA-1 (`ssh-rsa`), que o OpenSSH 8.8+ recusa por padrão; o app mostra o motivo e sugere ed25519/ECDSA. Chaves ECDSA em formato OpenSSH só sem passphrase; chaves PEM criptografadas não são lidas. Login por senha não foi testado contra um servidor real (o sshd de teste roda sem root, só com chave). Sem keyboard-interactive, jump host nem agente SSH.
- A host key desconhecida é aceita e gravada sem perguntar (TOFU); o fingerprint aparece na aba SSH e no Test Connection, e uma chave diferente bloqueia a conexão até "Forget Host Key". Falta um diálogo de confirmação na primeira conexão.
- Quando a sessão SSH cai, as conexões abertas por ela falham; o próximo connect abre outro túnel, mas não há reconexão automática.
- Builds de desenvolvimento são assinados ad hoc: a cada rebuild o macOS pode pedir de novo acesso às senhas no Keychain. Com assinatura Developer ID isso não acontece.
