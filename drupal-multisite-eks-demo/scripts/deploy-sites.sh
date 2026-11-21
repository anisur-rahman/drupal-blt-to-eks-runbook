#!/usr/bin/env bash
# Sequential per-site `drush deploy` (updatedb, config:import, cache:rebuild, deploy:hook).
# On Kubernetes the Helm chart runs this as one post-upgrade Job per site
# (helm/drupal/templates/deploy-jobs.yaml); this script is for running it by hand inside
# the app container. Run only with a verified backup and in a change window.
#   Usage: scripts/deploy-sites.sh https://site-a.example.org https://site-b.example.org
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 URI..." >&2; exit 2; }
for uri in "$@"; do
  echo "Deploying $uri"
  drush --uri="$uri" deploy -y
done
