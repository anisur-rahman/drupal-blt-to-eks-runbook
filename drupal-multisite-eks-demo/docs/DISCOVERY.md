# Steps 1–4: Discovery and acceptance
Record source Drupal/core and PHP versions; Acquia BLT dependencies and hooks; each site's actual Acquia DB name; hostname map; modules; search; external API integrations; storage; RPO/RTO; performance baseline; owners; compliance. **Do not assume site directory = database name.**

| Site directory | Hostname | Acquia database name | AWS database name | Owner |
|---|---|---|---|---|
| site_a | TBD | TBD | TBD | TBD |
| site_b | TBD | TBD | TBD | TBD |

Archive full database/files backups and prove a restore. For optimized migration dumps, explicitly document any intentionally excluded disposable tables.
