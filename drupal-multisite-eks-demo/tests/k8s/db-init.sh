#!/bin/sh
# Test stand-in for runbook Phase 14 (RDS): one database and one user per site, each
# user limited to its own database. Passwords come from the drupal-env Secret.
set -eu
for s in site_a site_b; do
  S=$(echo "$s" | tr '[:lower:]' '[:upper:]')
  pw=$(printenv "${S}_DB_PASSWORD")
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS ${s} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${s}_user'@'%' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON ${s}.* TO '${s}_user'@'%';
SQL
done
