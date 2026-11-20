<?php

/**
 * Hostname → site directory map for every environment.
 *
 * Local Docker Compose uses *.localhost; the Helm chart (EKS) uses the
 * hostnames in helm/drupal/values.yaml. Keep both in sync with that file.
 */
foreach ([
  'site_a' => ['site-a.localhost', 'site-a.example.org'],
  'site_b' => ['site-b.localhost', 'site-b.example.org'],
] as $dir => $hosts) {
  foreach ($hosts as $host) {
    $sites[$host] = $dir;
  }
}
