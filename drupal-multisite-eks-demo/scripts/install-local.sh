#!/usr/bin/env bash
# ONLY for the isolated local Docker demo. Installs both sites from the committed
# configuration (config/<site>/sync). Run from the demo folder with the stack up:
#   docker compose up -d --build --wait && scripts/install-local.sh
set -euo pipefail
for s in site_a site_b; do
  docker compose exec -T app drush --uri="http://${s//_/-}.localhost:8080" site:install --existing-config -y \
    --account-name=admin --account-pass=change-this-local-demo
done
echo "Open http://site-a.localhost:8080 and http://site-b.localhost:8080 (admin / change-this-local-demo)"
