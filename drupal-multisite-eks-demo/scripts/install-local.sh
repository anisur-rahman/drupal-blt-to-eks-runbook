#!/usr/bin/env bash
set -euo pipefail
# ONLY for isolated local Docker demo. Replace credentials before sharing environments.
for site in a b; do
  vendor/bin/drush --uri="http://site-${site}.localhost:8080" site:install standard \
    --site-name="Drupal Demo Site ${site^^}" --account-name=admin \
    --account-pass=change-this-local-demo --yes
  # Cron runs on a schedule (CronJob on EKS), not on page requests.
  vendor/bin/drush --uri="http://site-${site}.localhost:8080" pm:uninstall automated_cron --yes
done
