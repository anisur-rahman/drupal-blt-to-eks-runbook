# Execution evidence

What has actually been run, where, and what it showed. Anything not listed as run here has **not** been run. Each item says whether it ran on a local machine, on a GitHub Actions runner, or on AWS. Nothing has run on AWS.

## Environments

| Name | Where | Versions |
|---|---|---|
| Local | macOS (Apple silicon), Docker Desktop; project on an exFAT drive | Docker 29.2.1, PHP-FPM 8.3.37 (Alpine), nginx 1.27.5 (unprivileged), Drupal 11.4.13, Drush 13.8.1, MariaDB 11.4.13 |
| Local Kubernetes | kind v0.33.0 (Kubernetes v1.37.0), Helm v4.3.2 | metrics-server 0.9.0, Traefik v3.7.19 (stand-in for the ALB) |
| CI | GitHub Actions `ubuntu-latest` | Same images, built from this folder on every run; kind for Kubernetes |
| AWS | — | **Not run** |

## Results (nginx + PHP-FPM design, 2026-11-20)

| Test | Where | How | Result |
|---|---|---|---|
| Build `app` and `web` images | Local | `docker build --target app` / `--target web` | Pass: PHP 8.3 with pdo_mysql, gd, intl, opcache, apcu, redis; Drush 13.8.1; `app` runs as UID 82, `web` as UID 101; `php-fpm -tt` shows `clear_env = no`; `nginx -t` OK |
| Static checks | Local | ShellCheck, `composer validate`, validator tests, `helm lint`, `kubeconform -strict` | Pass: chart renders 10 valid resources (Deployment, Service, HPA, PDB, ConfigMap, 2 CronJobs, 2 deploy Jobs, Ingress) |
| Both sites install from committed config | Local | [`tests/compose/smoke.sh`](../tests/compose/smoke.sh) | Pass: `site:install --existing-config` |
| Host name routing | Local | Compose smoke test | Pass: `site-a.localhost` → 200 "Demo site_a", `site-b.localhost` → 200 "Demo site_b"; no `X-Powered-By` header |
| Separate databases, config and content | Local | Compose smoke test | Pass: each site reports its own database; a config change on site A is not visible on site B; an article created on site A is 200 on site A and 404 on site B |
| Unknown host name refused | Local | Compose smoke test | Pass: `/` and `/core/install.php` both 404 |
| nginx hardening | Local | Compose smoke test | Pass: `/.htaccess` 403, `*.yml` 403, `sites/site_a/settings.php` 404, `core/lib/Drupal.php` 404, `sites/*/private/` 403, `/healthz` 200 |
| Files | Local | Compose smoke test | Pass: PHP-FPM generates aggregated CSS that nginx serves; `private://` is `/mnt/private/<site>` and writable |
| Cron and `drush deploy` per site | Local | Compose smoke test | Pass |
| Helm install on Kubernetes | Local (kind) | [`tests/k8s/smoke.sh`](../tests/k8s/smoke.sh) | Pass: pod with `app` + `web` containers ready, 0 restarts |
| One database user per site | Local (kind) | kind smoke test | Pass: site A uses `site_a`/`site_a_user`, site B uses `site_b`/`site_b_user`; `site_a_user` is denied access to `site_b` |
| Both sites on Kubernetes | Local (kind) | kind smoke test | Pass: `site-a.example.org` and `site-b.example.org` → 200 with their own titles through the Service; unknown host → 404 |
| Files volume | Local (kind) | kind smoke test | Pass: aggregated CSS written by PHP-FPM is visible to nginx; private files writable per site |
| Per-site CronJobs | Local (kind) | kind smoke test | Pass: a Job created from each CronJob completed and set `system.cron_last` |
| Per-site `drush deploy` Jobs | Local (kind) | kind smoke test, `helm upgrade` | Pass: `drupal-deploy-site-a` 23:49:57–23:50:02, then `drupal-deploy-site-b` 23:50:02–23:50:07 |
| Ingress | Local (kind) | [`tests/k8s/scaling-ingress.sh`](../tests/k8s/scaling-ingress.sh) | Pass: both host names → 200 through Traefik using the chart's Ingress rules; unknown host → 404 |
| Autoscaling | Local (kind) | Ingress and autoscaling test | Pass: under load on uncached pages, CPU went to 586% of requests and the HPA scaled from 1 to 3 replicas |
| CI with the new design | CI | Workflow on the `local-production-design` branch | Pass: all three jobs, [run 44842516404](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/runs/44842516404) (2026-11-21); the HPA scaled 1 → 3 on the runner too |
| EKS deployment | AWS | — | **Not run** |
| Load test with real targets | — | — | **Not run** (the autoscaling test proves the HPA works, not capacity) |
| Backup and restore from Acquia | — | — | **Not run** |
| BLT removal (runbook Phases 5–7) | — | — | **Not run**: the demo starts without BLT |
| Reverse-proxy tests (runbook Phase 8) | — | — | **Not run** (needs a real ALB) |
| Rollback rehearsal | — | — | **Not run** |

Logs: [`compose-smoke.log`](evidence/compose-smoke.log), [`k8s-smoke.log`](evidence/k8s-smoke.log), [`k8s-scaling-ingress.log`](evidence/k8s-scaling-ingress.log).

## CI runs

Every push that changes this folder runs [the workflow](../../.github/workflows/demo-validate.yml); see the [list of runs](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/workflows/demo-validate.yml). Each run keeps the smoke test logs as downloadable artifacts (`compose-smoke-log`, `k8s-smoke-log`).

- First fully passing run with the nginx + PHP-FPM design (static checks, Compose smoke test, kind smoke test with Ingress and autoscaling): [run 44842516404](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/runs/44842516404).
- First fully passing run with the earlier single Apache image: [run 44817880453](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/runs/44817880453).

## Known warnings

- **HPA before metrics-server (kind):** until metrics-server is ready, the HPA logs `FailedGetResourceMetric`. EKS installs metrics-server as an add-on (runbook Phase 12).
- **`.htaccess` in config sync directories:** Drupal wants a protection file in each sync directory, so one is committed. The directories are outside the web root and nginx ignores `.htaccess`, so this only silences Drupal's warning.

## Screenshots

These were taken from the earlier single-container (Apache) version. Site A shows the slogan that was set only on site A; site B doesn't have it. The nginx + PHP-FPM version serves the same pages; see the logs above.

| Site A | Site B |
|---|---|
| ![Site A home page](evidence/site-a.png) | ![Site B home page](evidence/site-b.png) |

## Defects found by running the demo

The first version of this demo passed static checks (PHP syntax, Compose config, Helm lint). These problems only showed up when it was actually built and run.

### Single Apache image (first version)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `docker build` failed | Drush 13 pulls in Composer plugins that `composer.json` didn't allow | Listed them in `allow-plugins` |
| 2 | Drush couldn't bootstrap Drupal | No `installer-paths`, so core was installed in `vendor/drupal/core` | Added `composer/installers` and the standard paths |
| 3 | Every page was a PHP fatal error, but returned **HTTP 200** | Drupal 11.4's `index.php` needs `symfony/runtime`, which had been disabled while fixing #1; PHP printed errors into the page | Allowed `symfony/runtime`; production `php.ini`, so errors are logged instead of shown |
| 4 | Both sites returned HTTP 400 "host name is not valid" | A doubled backslash in the trusted-host pattern | One backslash |
| 5 | Unknown host names were offered the Drupal installer | No `sites/default`, so Drupal fell back to the installer | `sites/default/settings.php` returns 404 |
| 6 | Sites wouldn't load under the Helm chart's host names | `sites.php` only mapped `*.localhost` | Mapped both the local and the chart host names |
| 7 | Drupal created its config directory inside **public files** | `config_sync_directory` wasn't set | Set it to `../config/<site>/sync` |
| 8 | Cron sometimes skipped a site ("already running") | `automated_cron` ran cron on page requests alongside scheduled cron | Uninstalled `automated_cron` |
| 9 | `web/sites/*.php` files were missing from the repository | `.gitignore` ignored `web/`, so the `!` re-include rules had no effect | Fixed the ignore patterns |
| 10 | A PHP warning on every request (`zend.assertions`) | The production `php.ini` value `-1` can't be changed at runtime | Set `zend.assertions = 0` in the image |

Number 3 is why the smoke tests check page content and titles, not just status codes.

### nginx + PHP-FPM (runbook design)

Numbers 11–13 are defects in the runbook's own Phase 8–9 templates. The runbook is updated.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 11 | Settings would read empty database names, users and salts under PHP-FPM | PHP-FPM's default `clear_env = yes` hides the container environment from `getenv()` | `docker/php/zz-env.conf` sets `clear_env = no`; the build checks it |
| 12 | Plain-HTTP requests would be treated as HTTPS, and any client could claim HTTPS | The runbook's `fastcgi_param HTTPS $http_x_forwarded_proto` sets `HTTPS=http`, which PHP treats as on, from a client-controlled header | Removed; Drupal reads `X-Forwarded-Proto` only from `TRUSTED_PROXY_IPS` |
| 13 | Every request would fail once the Redis module's code is in the codebase | The runbook switches the cache backend when the module's code exists, even if the module isn't installed on the site | Also requires `REDIS_ENABLED=1`, set after the module is installed |
| 14 | `docker build` failed: `failed to xattr ._.dockerignore: operation not permitted` | On exFAT drives, macOS writes `._*` metadata files that BuildKit can't read, even when excluded; MariaDB would also run `._01-sites.sh` as an init script | Ignored in `.dockerignore`/`.gitignore`; smoke test removes them on macOS; Compose mounts only the one init script |
| 15 | Drush installed the sites, but every web request went to `/core/install.php`; nginx couldn't read its config | exFAT reports every file as `0700`, and `COPY` kept that | Dockerfile normalises permissions (`755`/`644`, `COPY --chmod=644`) |
| 16 | `drush deploy` failed: `stat failed for .../files/css/._css_...` | macOS wrote `._*` files into the bind-mounted files folder | Public and private files use Docker named volumes |
| 17 | Site install failed: files directory not writable | The `web` container sometimes seeded the empty volume first, with its root-owned directory | `web` mounts the volumes with `nocopy`, so only `app` (UID 82) seeds them |
| 18 | Viewing an article: "The website encountered an unexpected error" (HTTP 500) | Drupal 11.4's `standard` profile no longer creates content types, so the exported config had none | Added Article and Basic page from core recipes; the smoke test creates an article and views it |

Number 18 is why the smoke test now creates content and views it over HTTP: the earlier checks only loaded the home page.
