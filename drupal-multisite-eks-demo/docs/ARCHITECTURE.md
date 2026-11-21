# Architecture decisions (proposed)
- **BLT removal:** use standard Composer, Drush and CI; do not delete source settings or BLT custom tasks without mapping their replacements.
- **Multisite:** shared code, independent databases and public-file paths; single `sites.php` mapping; Helm site inventory drives CronJobs.
- **EKS vs ECS:** EKS matches the requested role and offers native Kubernetes orchestration; costs and operations are higher than ECS and must be justified.
- **Storage:** EFS for shared Drupal public files in the demo target, subject to performance tests; private files require dedicated protected storage and mounts.
- **Secrets:** the chart reads one Secret (`drupal-env`); with `externalSecrets.enabled` it renders the ExternalSecret that fills it from Secrets Manager (check the installed CRD version first).
- **Images:** one Dockerfile, two targets: `app` (PHP-FPM, code read-only, UID 82) and `web` (unprivileged nginx, UID 101), in one pod sharing localhost.
- **Settings:** each site's `settings.php` includes `settings.shared.php` last; everything environment-specific comes from a ConfigMap and a Secret (per-site DB user, password, hash salt).
- **Deployment:** immutable image digests; HPA owns replicas; PodDisruptionBudget; `drush deploy` runs once per site, in order, as Helm post-upgrade hook Jobs.
- **Security:** private RDS, strict network access, TLS/WAF, trusted proxy addresses validated for the actual ingress architecture.
