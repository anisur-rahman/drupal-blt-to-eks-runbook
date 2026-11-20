#!/usr/bin/env bash
# Deploy the Helm chart to a kind cluster and prove that it works end to end:
# both sites install into separate databases, serve pages by hostname, refuse
# unknown hosts, run cron from their CronJobs and write to the files volume.
#
# Needs: a kind cluster in the current kube context and the image drupal-multisite:ci
# loaded into it (kind load docker-image drupal-multisite:ci). Run from the demo folder.
set -euo pipefail
NS=drupal-smoke
SITES="site_a site_b"
host() { echo "${1//_/-}.example.org"; }
kc() { kubectl -n "$NS" "$@"; }
step() { echo; echo "=== $*"; }

step "Namespace, secret and test database"
kubectl create namespace "$NS"
kc create secret generic drupal-db \
  --from-literal=password="$(openssl rand -hex 16)" --from-literal=root-password="$(openssl rand -hex 16)"
kc create configmap db-init --from-file=docker/db-init/01-sites.sh
kc apply -f tests/k8s/mariadb.yaml
kc rollout status deploy/mariadb --timeout=180s

step "Helm install"
helm install drupal helm/drupal -n "$NS" \
  --set image.repository=drupal-multisite --set image.tag=ci --set image.digest= \
  --set database.host=mariadb --set autoscaling.minReplicas=1 \
  --wait --timeout 5m
kc get deploy,pod,svc,hpa,cronjob,pvc

step "Install both sites"
for s in $SITES; do
  kc exec deploy/drupal -- vendor/bin/drush --uri="https://$(host "$s")" site:install standard -y \
    --site-name="Demo ${s}" --account-name=admin --account-pass="$(openssl rand -hex 12)" 2>&1 | tail -1
  # The CronJob owns cron; stop Drupal from also running it on page requests.
  kc exec deploy/drupal -- vendor/bin/drush --uri="https://$(host "$s")" pm:uninstall automated_cron -y 2>&1 | tail -1
done

step "Each site uses its own database"
for s in $SITES; do
  db=$(kc exec deploy/drupal -- vendor/bin/drush --uri="https://$(host "$s")" status --field=db-name)
  echo "$s -> $db"; [ "$db" = "$s" ]
done
kc exec deploy/drupal -- vendor/bin/drush --uri="https://site-a.example.org" config:set system.site slogan "only-site-a" -y >/dev/null
[ -z "$(kc exec deploy/drupal -- vendor/bin/drush --uri=https://site-b.example.org config:get system.site slogan --format=string)" ]
echo "A config change on site_a is not visible on site_b"

step "HTTP routing through the Service"
kc port-forward svc/drupal 18080:80 >/tmp/pf.log 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18080/ && break; sleep 1; done
for s in $SITES; do
  h=$(host "$s")
  code=$(curl -s -o /tmp/page.html -w '%{http_code}' -H "Host: $h" http://127.0.0.1:18080/)
  title=$(grep -o '<title>[^<]*' /tmp/page.html | sed 's/<title>//')
  echo "$h -> $code \"$title\""
  [ "$code" = 200 ] || { echo "FAIL: $h returned $code"; exit 1; }
  grep -q "Demo $s" /tmp/page.html || { echo "FAIL: $h did not serve site $s"; exit 1; }
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.net" http://127.0.0.1:18080/)
echo "unknown.example.net -> $code"; [ "$code" = 404 ]
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.net" http://127.0.0.1:18080/core/install.php)
echo "unknown.example.net/core/install.php -> $code"; [ "$code" = 404 ]

step "Public files volume is writable by Drupal"
# Drupal writes each aggregated CSS file to public files the first time it is requested,
# so fetching the page's CSS URL proves the web server user can write to the volume.
for s in $SITES; do
  h=$(host "$s")
  css=$(curl -s -H "Host: $h" http://127.0.0.1:18080/ | grep -o "/sites/$s/files/css/[^\"?]*\.css" | head -1)
  [ -n "$css" ] || { echo "FAIL: no aggregated CSS link on $h"; exit 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" "http://127.0.0.1:18080$css")
  echo "$h$css -> $code"; [ "$code" = 200 ] || { echo "FAIL: CSS not written for $s"; exit 1; }
  kc exec deploy/drupal -- test -s "web$css" || { echo "FAIL: $css missing on the volume"; exit 1; }
done

step "Per-site CronJobs run"
for s in $SITES; do
  job="cron-now-${s//_/-}"
  kc create job "$job" --from="cronjob/drupal-cron-${s//_/-}"
  kc wait --for=condition=complete "job/$job" --timeout=180s
  kc logs "job/$job" | tail -2
  last=$(kc exec deploy/drupal -- vendor/bin/drush --uri="https://$(host "$s")" state:get system.cron_last)
  echo "$s system.cron_last=$last"; [ -n "$last" ] || { echo "FAIL: cron did not complete on $s"; exit 1; }
done

step "Probes"
kc get pod -l app=drupal -o jsonpath='{range .items[*]}{.metadata.name} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}'

echo; echo "SMOKE TEST PASSED"
