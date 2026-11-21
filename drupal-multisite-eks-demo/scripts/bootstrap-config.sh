#!/usr/bin/env bash
# One-time: create each site's configuration and export it to config/<site>/sync, so
# sites install with `site:install --existing-config` and `drush deploy` has a source of
# truth. Run from the demo folder with the Compose stack up; commit config/ afterwards.
# In a real migration this config comes from the existing Acquia sites (runbook Phase 8).
set -euo pipefail
for s in site_a site_b; do
  uri="http://${s//_/-}.localhost:8080"
  run() { docker compose exec -T app drush --uri="$uri" "$@"; }
  run site:install standard -y --site-name="Demo $s" --account-name=admin --account-pass="$(openssl rand -hex 12)"
  run pm:uninstall automated_cron -y   # cron runs from a CronJob (runbook Phase 15)
  # Drupal 11.4's standard profile no longer creates content types; they are recipes.
  run recipe /var/www/html/web/core/recipes/page_content_type
  run recipe /var/www/html/web/core/recipes/article_content_type
  docker compose run --rm --no-deps -v "$PWD/config:/var/www/html/config" app \
    drush --uri="$uri" config:export -y
done
