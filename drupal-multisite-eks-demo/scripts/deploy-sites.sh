#!/usr/bin/env bash
set -euo pipefail
# Sequential per-site deploy. Run only with a verified backup and change window.
for host in site-a.example.org site-b.example.org; do
  echo "Deploying $host"
  vendor/bin/drush --uri="https://$host" deploy -y
done
