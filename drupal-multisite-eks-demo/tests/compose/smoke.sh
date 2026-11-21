#!/usr/bin/env bash
# Local Docker Compose smoke test (runbook Phases 9-11): build the app (PHP-FPM) and
# web (nginx) images, install both sites from the committed configuration, then check
# hostname routing, database isolation, the unknown-host guard, nginx hardening,
# private files, cron and `drush deploy`.
# Run from the demo folder. Creates .env with random secrets if it is missing.
set -euo pipefail
SITES="site_a site_b"
url() { echo "http://${1//_/-}.localhost:8080"; }
drush() { local s=$1; shift; docker compose exec -T app drush --uri="$(url "$s")" "$@"; }
step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*"; exit 1; }
status() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://localhost:8080$2"; }

if [ ! -f .env ]; then
  { printf 'DB_ROOT_PASSWORD=%s\nDB_PASSWORD=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)"
    for s in $SITES; do printf '%s_HASH_SALT=%s\n' "$(echo "$s" | tr '[:lower:]' '[:upper:]')" "$(openssl rand -hex 32)"; done
  } > .env
fi

# macOS writes "._*" metadata files next to files on exFAT/network drives; BuildKit fails
# reading them (even when .dockerignore'd), so clear them before building.
[ "$(uname)" = Darwin ] && find . -name '._*' -type f -delete 2>/dev/null || true

step "Build and start (app = PHP-FPM, web = nginx sharing its network)"
docker compose up -d --build --wait
docker compose ps
echo "app uid: $(docker compose exec -T app id -u)  web uid: $(docker compose exec -T web id -u)"

step "Install both sites from the committed configuration"
for s in $SITES; do
  [ -f "config/$s/sync/system.site.yml" ] || fail "config/$s/sync is empty: run scripts/bootstrap-config.sh once"
  drush "$s" site:install --existing-config -y --account-name=admin --account-pass="$(openssl rand -hex 12)" 2>&1 | tail -1
done

step "Separate databases"
for s in $SITES; do
  db=$(drush "$s" status --field=db-name)
  echo "$s -> database $db"; [ "$db" = "$s" ] || fail "$s uses database $db"
done
drush site_a config:set system.site slogan only-site-a -y >/dev/null
[ -z "$(drush site_b config:get system.site slogan --format=string)" ] || fail "site_a config leaked into site_b"
echo "A config change on site_a is not visible on site_b"
drush site_a config:set system.site slogan '' -y >/dev/null

step "Content is per site: an article created on site_a is served only by site_a"
for s in $SITES; do
  types=$(drush "$s" php:eval 'echo implode(",", array_keys(\Drupal\node\Entity\NodeType::loadMultiple()));')
  echo "$s content types: $types"; [ "$types" = "article,page" ] || fail "$s content types: $types"
done
# shellcheck disable=SC2016  # PHP code, not shell variables
nid=$(drush site_a php:eval '$n = \Drupal\node\Entity\Node::create(["type" => "article", "title" => "Only on site A", "status" => 1]); $n->save(); echo $n->id();')
code=$(curl -s -o /tmp/node.html -w '%{http_code}' -H "Host: site-a.localhost" "http://localhost:8080/node/$nid")
echo "site-a.localhost/node/$nid -> $code"; [ "$code" = 200 ] || fail "site_a article returned $code"
grep -q "Only on site A" /tmp/node.html || fail "article not served on site_a"
code=$(status site-b.localhost "/node/$nid"); echo "site-b.localhost/node/$nid -> $code"; [ "$code" = 404 ] || fail "site_b served site_a's article"

step "Config sync directory is outside public files"
for s in $SITES; do
  dir=$(drush "$s" php:eval 'echo \Drupal\Core\Site\Settings::get("config_sync_directory");')
  echo "$s config_sync_directory=$dir"; [ "$dir" = "../config/$s/sync" ] || fail "unexpected sync dir $dir"
done

step "HTTP routing by hostname (nginx -> PHP-FPM)"
for s in $SITES; do
  h="${s//_/-}.localhost"
  code=$(curl -s -D /tmp/headers.txt -o /tmp/page.html -w '%{http_code}' -H "Host: $h" http://localhost:8080/)
  echo "$h -> $code $(grep -o '<title>[^<]*' /tmp/page.html | sed 's/<title>//')"
  [ "$code" = 200 ] || fail "$h returned $code"
  grep -q "Demo $s" /tmp/page.html || fail "$h did not serve $s"
  ! grep -qi '^x-powered-by' /tmp/headers.txt || fail "X-Powered-By header exposed"
done
for path in / /core/install.php; do
  code=$(status unknown.example.net "$path")
  echo "unknown.example.net$path -> $code"; [ "$code" = 404 ] || fail "unknown host got $code"
done

step "nginx hardening"
check() { code=$(status site-a.localhost "$1"); echo "$1 -> $code (want $2)"; [ "$code" = "$2" ] || fail "$1 returned $code"; }
check /healthz 200
check /.htaccess 403
check /core/core.services.yml 403
check /sites/site_a/settings.php 404
check /core/lib/Drupal.php 404
check /sites/site_a/private/x.txt 403

step "Public files written by PHP-FPM, served by nginx"
css=$(curl -s -H "Host: site-a.localhost" http://localhost:8080/ | grep -o '/sites/site_a/files/css/[^"]*' | head -1 | sed 's/&amp;/\&/g')
code=$(status site-a.localhost "$css"); echo "${css%%\?*} -> $code"; [ "$code" = 200 ] || fail "aggregated CSS"
docker compose exec -T web test -s "/var/www/html/web${css%%\?*}" || fail "nginx can't see ${css%%\?*}"

step "Private files directory"
for s in $SITES; do
  out=$(drush "$s" php:eval 'echo \Drupal::service("file_system")->realpath("private://"), " ", is_writable("private://") ? "writable" : "NOT writable";')
  echo "$s private:// -> $out"; [ "$out" = "/mnt/private/$s writable" ] || fail "private files on $s: $out"
done

step "Cron"
for s in $SITES; do
  drush "$s" cron
  last=$(drush "$s" state:get system.cron_last)
  echo "$s system.cron_last=$last"; [ -n "$last" ] || fail "cron did not complete on $s"
done

step "drush deploy per site (no pending changes, so a clean no-op)"
for s in $SITES; do
  drush "$s" deploy -y 2>&1 | tail -1
done

echo; echo "COMPOSE SMOKE TEST PASSED"
