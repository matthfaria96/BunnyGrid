# Brand logos

Used only in the connection-type picker (New Connection, Edit Connection header) to identify each
product. All logos and names are trademarks of their respective owners; their use here does not imply
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

## Text tiles (no logo shipped)

These brands are not in Simple Icons (several were removed at the owner's request) and their owners'
trademark guidelines don't grant a general licence to use the logo, so the picker shows the name as
text in the brand colour instead (`Components/BrandLogo.swift`). No artwork was copied.

| Brand | Tile text | Colour | Why |
|---|---|---|---|
| AWS (all Amazon services) | aws | #FF9900 | Removed from Simple Icons; AWS trademark guidelines require permission for logo use |
| Microsoft Azure | Azure | #0078D4 | Removed from Simple Icons; Microsoft logo use requires permission |
| Microsoft SQL Server | SQL Server | #CC2927 | Removed from Simple Icons; Microsoft logo use requires permission |
| Microsoft Garnet | Garnet | #BF1A24 | No permissively licensed logo found |
| Oracle / Oracle Cloud | ORACLE | #F80000 | Removed from Simple Icons; Oracle trademark guidelines restrict logo use |
| Tencent Cloud | Tencent Cloud | #0052D9 | Not in Simple Icons; no public permissive brand kit |
| OceanBase | OceanBase | #006AFF (approx.) | Not in Simple Icons; no public permissive brand kit |
| Kingbase | Kingbase | #E60012 (approx.) | Not in Simple Icons; no public permissive brand kit |
| HighGo | HighGo | #C8102E (approx.) | Not in Simple Icons; no public permissive brand kit |
| IvorySQL | IvorySQL | #E8A33D (approx.) | Not in Simple Icons |
