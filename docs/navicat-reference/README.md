# Navicat reference captures

Captured from the user's own Navicat Premium 17.3 with REA's native UI observation (accessibility tree plus a
screenshot of the selected window) through `scripts/navicat-ref/observe.sh` and `scenario.sh`.
Nothing here was decompiled. Use these as layout and wording references only; never ship Navicat's artwork.

| File | Screen |
|---|---|
| main-window | Main window with a connection selected (Objects columns, Info pane card) |
| ai-pane-step2 | AI pane before any assistant is configured |
| options-*.png | Options window: general, tabs, code-completion, editor, records, auto-recovery, ai, environment, advanced |
| newconn-dialog | New Connection type picker |
| newconn-sqlite-form, conn-sqlite-* | SQLite connection form: General, Advanced, Databases, HTTP, Remarks |

Each `.tree.txt` lists roles, titles, values and AX child-index paths (usable as REA scenario steps).
| objects-tables, main-open, main-db | Objects for a SQLite database (Root Page, Has Indexes, Has Triggers) and the database info card |
| table-view, table-pane-ddl, table-pane-field | Table viewer: toolbar, grid footer, right pane General / DDL / Field / AI Assistant |
| query-new, query-result, query-result-info, query-message, query-error-summary | Query editor: toolbars, Message / Summary / Result tabs, Data / Info, error summary |
| query-pane-snippets, query-pane-identifiers | Query right pane: Code Snippet and Identifiers |
| table-design, design-* | Table Design: Fields (with field properties), Indexes, Foreign Keys, Uniques, Triggers, Options, SQL Preview |
| context-connection | Connection context menu |
| askai-not-configured-alert | Ask AI before an assistant exists |
| new-model-dialog, model-untitled | Model (opened by accident while capturing; not used) |
