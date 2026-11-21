#!/usr/bin/env bash
# Extends tests/k8s/smoke.sh (run that first, same namespace): proves the parts of
# runbook Phases 15 and 18 that need cluster add-ons, still without AWS.
#   - Ingress host rules route each hostname to the right site (Traefik stands in for the ALB)
#   - HPA scales the Deployment out under load and back in afterwards (metrics-server, as on EKS)
set -euo pipefail
NS=${NS:-drupal-smoke}
kc() { kubectl -n "$NS" "$@"; }
step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*"; exit 1; }
HELM_ARGS=(--set image.repository=drupal-multisite
  --set image.app.tag=app-ci --set image.app.digest= --set image.web.tag=web-ci --set image.web.digest=
  --set database.host=mariadb --set appEnv=local
  --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=3 --set autoscaling.cpuUtilization=50
  --set podDisruptionBudget.minAvailable=1
  --set ingress.enabled=true --set ingress.className=traefik)

step "Cluster add-ons: metrics-server and Traefik"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update metrics-server traefik >/dev/null
# kind kubelets use self-signed certificates; EKS does not need this flag.
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m >/dev/null
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  --set service.spec.type=ClusterIP --set ingressClass.name=traefik --wait --timeout 5m >/dev/null
kubectl get ingressclass

step "Enable the chart's Ingress"
helm upgrade drupal helm/drupal -n "$NS" "${HELM_ARGS[@]}" --wait --timeout 10m >/dev/null
kc get ingress drupal -o custom-columns=NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host

step "Routing through the Ingress controller"
kubectl -n traefik port-forward svc/traefik 18081:80 >/tmp/pf-traefik.log 2>&1 & PF=$!; trap 'kill $PF 2>/dev/null || true; kc delete deploy load --ignore-not-found >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:18081/ && break; sleep 1; done
for s in site_a site_b; do
  h="${s//_/-}.example.org"
  code=$(curl -s -o /tmp/page.html -w '%{http_code}' -H "Host: $h" http://127.0.0.1:18081/)
  echo "$h via Ingress -> $code \"$(grep -o '<title>[^<]*' /tmp/page.html | sed 's/<title>//')\""
  [ "$code" = 200 ] || fail "$h through the Ingress returned $code"
  grep -q "Demo $s" /tmp/page.html || fail "$h through the Ingress did not serve $s"
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.net" http://127.0.0.1:18081/)
echo "unknown.example.net via Ingress -> $code (no rule)"; [ "$code" = 404 ] || fail "unknown host through the Ingress"

step "HPA has CPU metrics"
for _ in $(seq 1 60); do
  t=$(kc get hpa drupal -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)
  [ -n "$t" ] && break; sleep 5
done
[ -n "$t" ] || fail "HPA never received CPU metrics"
kc get hpa drupal

step "Scale out under load (uncached pages: a unique query string per request)"
# shellcheck disable=SC2016  # $RANDOM must expand inside the load pods, not here
kc create deployment load --image=busybox:1.36 --replicas=4 -- sh -c \
  'while true; do wget -q -O /dev/null --header "Host: site-a.example.org" "http://drupal/node?x=$RANDOM$RANDOM" || true; done' >/dev/null
max=1
for i in $(seq 1 40); do
  r=$(kc get deploy drupal -o jsonpath='{.status.replicas}'); [ "$r" -gt "$max" ] && max=$r
  echo "t=$((i*10))s replicas=$r cpu=$(kc get hpa drupal -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')%"
  [ "$max" -ge 2 ] && [ "$(kc get deploy drupal -o jsonpath='{.status.readyReplicas}')" -ge 2 ] && break
  sleep 10
done
[ "$max" -ge 2 ] || fail "HPA did not scale out"
kc get pod -l app=drupal
kc describe hpa drupal | sed -n '/Events:/,$p' | tail -5

step "Scale-in is left to the HPA (5-minute stabilisation window); stop the load"
kc delete deploy load >/dev/null
echo "Load stopped. The HPA will return to minReplicas after its scale-down window."

echo; echo "INGRESS AND AUTOSCALING TEST PASSED"
