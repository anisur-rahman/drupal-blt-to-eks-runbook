#!/usr/bin/env bash
# Local Docker Compose smoke test: build, start, install both sites, then check
# hostname routing, database isolation, the unknown-host guard and cron.
# Run from the demo folder. Creates .env with random passwords if it is missing.
set -euo pipefail
SITES="site_a site_b"
url() { echo "http://${1//_/-}.localhost:8080"; }
drush() { docker compose exec -T app vendor/bin/drush "$@"; }
step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*"; exit 1; }

if [ ! -f .env ]; then
  printf 'DB_ROOT_PASSWORD=%s\nDB_PASSWORD=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env
fi

step "Build and start"
docker compose up -d --build --wait
docker compose ps

step "Install both sites"
for s in $SITES; do
  drush --uri="$(url "$s")" site:install standard -y --site-name="Demo $s" \
    --account-name=admin --account-pass="$(openssl rand -hex 12)" 2>&1 | tail -1
  # Cron is scheduled outside Drupal (CronJob on EKS), not on page requests.
  drush --uri="$(url "$s")" pm:uninstall automated_cron -y 2>&1 | tail -1
done

step "Separate databases"
for s in $SITES; do
  db=$(drush --uri="$(url "$s")" status --field=db-name)
  echo "$s -> database $db"; [ "$db" = "$s" ] || fail "$s uses database $db"
done
drush --uri="$(url site_a)" config:set system.site slogan only-site-a -y >/dev/null
[ -z "$(drush --uri="$(url site_b)" config:get system.site slogan --format=string)" ] \
  || fail "site_a config leaked into site_b"
echo "A config change on site_a is not visible on site_b"

step "Config sync directory is outside public files"
for s in $SITES; do
  dir=$(drush --uri="$(url "$s")" php:eval 'echo \Drupal\Core\Site\Settings::get("config_sync_directory");')
  echo "$s config_sync_directory=$dir"; [ "$dir" = "../config/$s/sync" ] || fail "unexpected sync dir $dir"
done

step "HTTP routing by hostname"
for s in $SITES; do
  h="${s//_/-}.localhost"
  code=$(curl -s -o /tmp/page.html -w '%{http_code}' -H "Host: $h" http://localhost:8080/)
  echo "$h -> $code $(grep -o '<title>[^<]*' /tmp/page.html | sed 's/<title>//')"
  [ "$code" = 200 ] || fail "$h returned $code"
  grep -q "Demo $s" /tmp/page.html || fail "$h did not serve $s"
done
for path in / /core/install.php; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.net" "http://localhost:8080$path")
  echo "unknown.example.net$path -> $code"; [ "$code" = 404 ] || fail "unknown host got $code"
done

step "Cron"
for s in $SITES; do
  drush --uri="$(url "$s")" cron
  last=$(drush --uri="$(url "$s")" state:get system.cron_last)
  echo "$s system.cron_last=$last"; [ -n "$last" ] || fail "cron did not complete on $s"
done

echo; echo "COMPOSE SMOKE TEST PASSED"
