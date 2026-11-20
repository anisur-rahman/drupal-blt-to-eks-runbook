#!/bin/sh
set -eu
# LOCAL DEMO ONLY: two databases and one shared local user.
mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS site_b CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON site_b.* TO 'drupal'@'%';
FLUSH PRIVILEGES;
SQL
