#!/usr/bin/env bash
# Deploy the Helm chart to a kind cluster and prove it end to end (runbook Phase 15):
# nginx + PHP-FPM pods serve both sites by hostname from separate databases with
# separate users, refuse unknown hosts, write public and private files, run cron from
# per-site CronJobs, and run `drush deploy` per site, in order, on `helm upgrade`.
#
# Needs: a kind cluster in the current kube context with drupal-multisite:app-ci and
# drupal-multisite:web-ci loaded (kind load docker-image ...). Run from the demo folder.
set -euo pipefail
NS=${NS:-drupal-smoke}
SITES="site_a site_b"
host() { echo "${1//_/-}.example.org"; }
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
kc() { kubectl -n "$NS" "$@"; }
app() { kc exec deploy/drupal -c app -- "$@"; }
drush() { local s=$1; shift; app drush --uri="https://$(host "$s")" "$@"; }
step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*"; exit 1; }
HELM_ARGS=(--set image.repository=drupal-multisite
  --set image.app.tag=app-ci --set image.app.digest= --set image.web.tag=web-ci --set image.web.digest=
  --set database.host=mariadb --set appEnv=local
  --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=3 --set podDisruptionBudget.minAvailable=1)

step "Namespace, secrets and test database (one user per site)"
kubectl create namespace "$NS"
secret_args=()
for s in $SITES; do S=$(upper "$s")
  secret_args+=(--from-literal="${S}_DB_USER=${s}_user" --from-literal="${S}_DB_PASSWORD=$(openssl rand -hex 16)"
    --from-literal="${S}_HASH_SALT=$(openssl rand -hex 32)")
done
kc create secret generic drupal-env "${secret_args[@]}"
kc create secret generic db-root --from-literal=password="$(openssl rand -hex 16)"
kc create configmap db-init --from-file=tests/k8s/db-init.sh
kc apply -f tests/k8s/mariadb.yaml
kc rollout status deploy/mariadb --timeout=180s

step "Helm install"
helm install drupal helm/drupal -n "$NS" "${HELM_ARGS[@]}" --wait --timeout 5m
kc get deploy,pod,svc,hpa,pdb,cronjob,pvc,configmap

step "Pod runs nginx + PHP-FPM as non-root"
kc get pod -l app=drupal -o jsonpath='{range .items[0].spec.containers[*]}{.name}={.image} {end}{"\n"}'
echo "app uid: $(app id -u)  web uid: $(kc exec deploy/drupal -c web -- id -u)"
[ "$(app id -u)" = 82 ] && [ "$(kc exec deploy/drupal -c web -- id -u)" = 101 ] || fail "unexpected UIDs"

step "Install both sites from the committed configuration"
for s in $SITES; do
  drush "$s" site:install --existing-config -y --account-name=admin --account-pass="$(openssl rand -hex 12)" 2>&1 | tail -1
done

step "Each site uses its own database and its own database user"
for s in $SITES; do
  out="$(drush "$s" status --field=db-name),$(drush "$s" status --field=db-username)"
  echo "$s -> $out"; [ "$out" = "$s,${s}_user" ] || fail "$s uses $out"
done
drush site_a config:set system.site slogan "only-site-a" -y >/dev/null
[ -z "$(drush site_b config:get system.site slogan --format=string)" ] || fail "config leaked"
echo "A config change on site_a is not visible on site_b"
pw=$(kc get secret drupal-env -o jsonpath='{.data.SITE_A_DB_PASSWORD}' | base64 -d)
if kc exec deploy/mariadb -- mariadb -usite_a_user -p"$pw" -e 'SELECT 1 FROM site_b.users LIMIT 1' >/dev/null 2>&1; then
  fail "site_a_user can read site_b's database"
fi
echo "site_a_user is denied access to site_b's database"

step "HTTP routing through the Service (nginx -> PHP-FPM)"
kc port-forward svc/drupal 18080:80 >/tmp/pf.log 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18080/healthz && break; sleep 1; done
for s in $SITES; do
  h=$(host "$s")
  code=$(curl -s -o /tmp/page.html -w '%{http_code}' -H "Host: $h" http://127.0.0.1:18080/)
  title=$(grep -o '<title>[^<]*' /tmp/page.html | sed 's/<title>//')
  echo "$h -> $code \"$title\""
  [ "$code" = 200 ] || fail "$h returned $code"
  grep -q "Demo $s" /tmp/page.html || fail "$h did not serve site $s"
done
for path in / /core/install.php; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.net" "http://127.0.0.1:18080$path")
  echo "unknown.example.net$path -> $code"; [ "$code" = 404 ] || fail "unknown host got $code"
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: site-a.example.org" http://127.0.0.1:18080/healthz)
echo "/healthz -> $code"; [ "$code" = 200 ] || fail "healthz"

step "Public files volume is writable by PHP-FPM and served by nginx"
for s in $SITES; do
  h=$(host "$s")
  url=$(curl -s -H "Host: $h" http://127.0.0.1:18080/ | grep -o "/sites/$s/files/css/[^\"]*" | head -1 | sed 's/&amp;/\&/g')
  [ -n "$url" ] || fail "no aggregated CSS link on $h"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" "http://127.0.0.1:18080$url")
  echo "$h ${url%%\?*} -> $code"; [ "$code" = 200 ] || fail "CSS not generated for $s"
  kc exec deploy/drupal -c web -- test -s "/var/www/html/web${url%%\?*}" || fail "nginx can't see ${url%%\?*}"
done

step "Private files directory is writable and outside the web root"
for s in $SITES; do
  out=$(drush "$s" php:eval 'echo \Drupal::service("file_system")->realpath("private://"), " ", is_writable("private://") ? "writable" : "NOT writable";')
  echo "$s private:// -> $out"; [ "$out" = "/mnt/private/$s writable" ] || fail "private files on $s: $out"
done

step "Per-site CronJobs run"
for s in $SITES; do
  job="cron-now-${s//_/-}"
  kc create job "$job" --from="cronjob/drupal-cron-${s//_/-}"
  kc wait --for=condition=complete "job/$job" --timeout=180s
  last=$(drush "$s" state:get system.cron_last)
  echo "$s system.cron_last=$last"; [ -n "$last" ] || fail "cron did not complete on $s"
done

step "helm upgrade runs drush deploy once per site, in order"
helm upgrade drupal helm/drupal -n "$NS" "${HELM_ARGS[@]}" --wait --timeout 10m
kc get jobs -l job=deploy -o custom-columns=JOB:.metadata.name,COMPLETE:.status.succeeded,START:.status.startTime,END:.status.completionTime
for s in $SITES; do
  [ "$(kc get job "drupal-deploy-${s//_/-}" -o jsonpath='{.status.succeeded}')" = 1 ] || fail "deploy job for $s did not succeed"
  kc logs "job/drupal-deploy-${s//_/-}" | grep -E 'success|Finished performing deploy' | tail -1
done
a_end=$(kc get job drupal-deploy-site-a -o jsonpath='{.status.completionTime}')
b_start=$(kc get job drupal-deploy-site-b -o jsonpath='{.status.startTime}')
echo "site_a finished $a_end, site_b started $b_start"; [[ "$b_start" > "$a_end" || "$b_start" == "$a_end" ]] || fail "deploys overlapped"

step "Probes"
kc get pod -l app=drupal -o jsonpath='{range .items[*]}{.metadata.name}{range .status.containerStatuses[*]} {.name}:ready={.ready},restarts={.restartCount}{end}{"\n"}{end}'

echo; echo "SMOKE TEST PASSED"
