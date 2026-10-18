# Brand logos

Used in the connection-type picker (New Connection, Edit Connection header) and wherever an AI assistant
is shown (profile menu, AI pane, Ask AI, Settings › AI) to identify each product. All logos and names are trademarks of their respective owners; their use here does not imply
endorsement.

SVG paths are from **Simple Icons 16.33.0** (npm `simple-icons`, tarball
`https://registry.npmjs.org/simple-icons/-/simple-icons-16.33.0.tgz`), licence **CC0-1.0**
(https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md). Simple Icons notes that the
marks may still be subject to trademark law (see its DISCLAIMER.md). Files are unmodified, renamed to
`brand-<slug>.svg`; the app tints them with the brand hex from `data/simple-icons.json`.

| File | Slug | Brand hex | Upstream source (per Simple Icons) |
|---|---|---|---|
| brand-postgresql.svg | postgresql | #4169E1 | https://wiki.postgresql.org/wiki/Logo |
| brand-mysql.svg | mysql | #4479A1 | https://www.mysql.com/about/legal/logos.html |
| brand-mariadb.svg | mariadb | #003545 | https://mariadb.com/about-us/logos/ |
| brand-sqlite.svg | sqlite | #003B57 | https://github.com/sqlite/sqlite (art/sqlite370.eps) |
| brand-mongodb.svg | mongodb | #47A248 | https://www.mongodb.com/pressroom |
| brand-redis.svg | redis | #FF4438 | https://redis.io/brand-guidelines |
| brand-snowflake.svg | snowflake | #29B5E8 | https://www.snowflake.com/brand-guidelines/ |
| brand-googlecloud.svg | googlecloud | #4285F4 | https://cloud.google.com |
| brand-alibabacloud.svg | alibabacloud | #FF6A00 | https://www.alibabagroup.com/en/ir/reports |
| brand-huawei.svg | huawei | #FF0000 | https://e.huawei.com/ph/material/partner/0a72728b864949c48b22106454352483 |
| brand-tidb.svg | tidb | #DC150B | https://www.pingcap.com/tidb-brand-guidelines/ |
| brand-fujitsu.svg | fujitsu | #FF0000 | https://www.fujitsu.com/global/about/brandmanagement/logo/ |
| brand-claude.svg | claude | #D97757 | https://claude.ai |
| brand-googlegemini.svg | googlegemini | #8E75B2 | https://gemini.google.com |
| brand-deepseek.svg | deepseek | #5786FE | https://www.deepseek.com |
| brand-mistralai.svg | mistralai | #FA520F | https://chat.mistral.ai |
| brand-ollama.svg | ollama | #000000 | https://github.com/ollama/ollama/issues/2152#issuecomment-1905286922 |
| brand-lmstudio.svg | lmstudio | #000000 | https://files.lmstudio.ai/lmstudio_icon2.svg |

OpenAI (ChatGPT) and xAI (Grok) are not in Simple Icons (removed at the owners' request), so the app shows
a text tile for them (`AIProvider.brand`).

## From the owners' own published files

Downloaded 2026-10-17. Only the outlines were kept: each file was rebuilt from the original path data
(no scripts, styles, links, ids or metadata), recoloured to one fill so the app can tint it like the
Simple Icons marks, and padded to a square viewBox. The artwork is otherwise unchanged.

| File | Brand hex | Source | Licence / terms | What we did |
|---|---|---|---|---|
| brand-ivorysql.svg | #FBAF42 (the logo's gold, `.st1`) | `static/img/logo.svg` in https://github.com/IvorySQL/Ivory-www (the ivorysql.org site repo, branch `main`) | Repository licence **CC0-1.0** ("Creative Commons Zero v1.0 Universal"); IvorySQL itself is Apache-2.0 | The white outline and gold tusk fills merged into one path |
| brand-oceanbase.svg | #0096FE (the logo gradient's start colour) | `images/logo.svg` in https://github.com/oceanbase/oceanbase (commit a7d679d, 2026-07-14) | Repository licence **Apache-2.0**: copyright licence to reproduce and distribute; §6 grants no trademark rights "except as required for reasonable and customary use in describing the origin of the Work". No OceanBase trademark/logo policy is published | Only the symbol (the three gradient paths `cls-1..3`), without the "OceanBase" wordmark; gradient replaced by one fill |
| brand-kingbase.svg | #C9151E (the red of the owner's RGB PNGs) | "Logo下载 / LOGO组合包下载" on https://www.kingbase.com.cn/about/about.html → `uploadnew/file/2024/10/29/86eef8cb-6e94-4620-8d6f-d1d9f79ad24c.zip` (dated 2024-09-06; "KING BASE商标源文件(金仓数据库).ai") | Offered publicly by 电科金仓 (CETC Kingbase) as a logo pack "提供矢量图、JPG、PNG版" with **no usage terms attached**; the site has no trademark notice | The stacked English wordmark ("英文-竖版" artboard) converted from the PDF-compatible .ai to SVG |

Basis for these three: the owner publishes the artwork for download (under CC0 / Apache-2.0, or as a
public logo pack) and no published policy of theirs restricts referring to the product with it. It is
used only to identify the product (nominative use), never for BunnyGrid itself, and implies no endorsement.

## Text tiles (no logo shipped)

These owners' published terms don't allow their logos in third-party software, or no permission-granting
source exists, so the picker shows the name as text in the brand colour (`Components/BrandLogo.swift`).
No artwork was copied. Checked 2026-10-17.

| Brand | Tile text | Colour (source) | Why no logo |
|---|---|---|---|
| AWS (all Amazon services) | aws | #FF9900 (AWS logo orange; AWS publishes no colour spec publicly) | AWS Trademark Guidelines (https://aws.amazon.com/trademark-guidelines/) §13: "AWS does not object to fair use of its marks by third parties ... Any such use should be in plain text only (no logos)"; §10 lists "product icons" as protected trade dress. The AWS Architecture Icons (https://aws.amazon.com/architecture/icons/, package of 2026-07-31) are allowed only "to create architecture diagrams" and in "whitepapers, presentations, data sheets, and posters" |
| Microsoft Azure | Azure | #0078D4 (Azure blue, as in Microsoft's Azure icons; approx.) | Azure Architecture Icons terms (https://learn.microsoft.com/azure/architecture/icons/, V24, July 2026): "Microsoft permits the use of these icons in architectural diagrams, training materials, or documentation. You can copy, distribute, and display the icons only for the permitted use unless granted explicit permission by Microsoft." Microsoft Trademark & Brand Guidelines: "Don't use Microsoft's logos, icons, or designs, in any manner"; app/product icons (incl. Azure) "will require a license first" |
| Microsoft SQL Server | SQL Server | #CC2927 (approx.; no public colour spec) | Same Microsoft guidelines as Azure |
| Microsoft Garnet | Garnet | #7A060C (face of the logo in `website/static/img/logo_128.png`, github.com/microsoft/garnet) | The repo is MIT, but its README says "Authorized use of Microsoft trademarks or logos is subject to and must follow Microsoft's Trademark & Brand Guidelines", which require a licence for logos |
| Oracle / Oracle Cloud | ORACLE | #C74634 ("Oracle Red, PMS 180 C, CMYK 3/91/86/12", Oracle Redwood Brand Style Guide, Oct 2024, p. 14) | Third Party Usage Guidelines for Oracle Logos (https://www.oracle.com/legal/logos/): "you are generally not able to use Oracle logos unless you are specifically licensed or authorized to use them". The OCI architecture icon toolkit is offered only "to draw custom architecture diagrams" |
| Tencent Cloud | Tencent Cloud | #0052D9 (fill of the logo in tencentcloud.com's top navigation) | Tencent website terms (https://www.tencent.com/en-us/service-agreement.html): trademarks, logos and "other distinctive brand features ... you can only use them with our prior written permission". The brandbook is not public |
| HighGo | HighGo | #EC6C00 (accent fill of the logo on highgo.com) | No logo download, press kit or terms published; the only copy is the website's own artwork |
