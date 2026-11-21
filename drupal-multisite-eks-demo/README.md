# Drupal Multisite → AWS EKS: Demo

**Status: working reference implementation, tested locally and on a kind cluster; not deployed to AWS.** This project accompanies the [BLT to EKS runbook](../RUNBOOK.md). It runs two Drupal 11 sites on one codebase, with separate databases, files and configuration. It doesn't depend on Acquia BLT. It uses the runbook's production design: an nginx + PHP-FPM image pair, environment-driven settings, and a Helm chart with per-site cron and deploy Jobs. No Acquia environment, AWS account or production data is involved.

What is proven, and how, is in [`docs/EVIDENCE.md`](docs/EVIDENCE.md).

## Architecture

```
Host name ─▶ nginx :8080 (web image, UID 101) ─▶ PHP-FPM :9000 (app image, UID 82)
                                                   │ sites.php: host name → site folder
                                                   ▼
             site_a: database site_a, files sites/site_a/files, /mnt/private/site_a, config/site_a/sync
             site_b: database site_b, files sites/site_b/files, /mnt/private/site_b, config/site_b/sync
```

- **One codebase, many sites:** `web/sites/sites.php` maps every host name to a site folder. Each site's `settings.php` sets `$site_name` and includes [`settings.shared.php`](web/sites/settings.shared.php), which reads the database, hash salt, trusted hosts and proxy addresses from environment variables (runbook Phase 8).
- **Two images from one [`Dockerfile`](Dockerfile)** (Phase 9): `app` (PHP-FPM 8.3, Drush 13, code read-only and owned by root) and `web` (unprivileged nginx with the same web root). They run side by side, sharing localhost, in a Compose network or a Kubernetes pod.
- **Kubernetes ([`helm/drupal`](helm/drupal))** (Phase 15): a Deployment with the two containers, Service, HPA, PodDisruptionBudget, a ConfigMap, one CronJob per site, one `drush deploy` Job per site run in order on `helm upgrade`, optional Ingress and an optional ExternalSecret.
- **EKS target (runbook):** ALB → pods → RDS; EFS for files; Secrets Manager via External Secrets; images in ECR. Provisioning these is a prerequisite and isn't automated here.

Unknown host names get a 404 instead of Drupal's installer (`web/sites/default/settings.php`).

## Run it locally

Needs Docker with Compose v2.

```bash
tests/compose/smoke.sh
```

This builds both images, starts the stack, installs both sites from the committed configuration, and runs the checks listed under [Continuous integration](#continuous-integration). Then open the sites:

```bash
echo "127.0.0.1 site-a.localhost site-b.localhost" | sudo tee -a /etc/hosts   # if they don't resolve
open http://site-a.localhost:8080 http://site-b.localhost:8080
docker compose exec app drush --uri=http://site-a.localhost:8080 user:login   # one-time admin login link
```

Or do it step by step:

```bash
cp .env.example .env               # then set your own passwords and hash salts
docker compose up -d --build --wait
scripts/install-local.sh           # installs both sites with --existing-config
curl -I -H 'Host: site-b.localhost' http://localhost:8080/
```

`install-local.sh` uses a fixed demo admin password for isolated local use only. Clean up with `docker compose down -v`.

Public and private files live in Docker named volumes, not host folders. On macOS, exFAT and network drives add `._*` files that break Drupal's file cleanup. To load restored files: `docker compose cp <dir>/. app:/var/www/html/web/sites/<site>/files/`.

### Configuration

Each site installs from `config/<site>/sync`, and `drush deploy` imports from there. [`scripts/bootstrap-config.sh`](scripts/bootstrap-config.sh) created the committed configuration once. In a real migration, this configuration is exported from the existing Acquia sites instead. Drupal 11.4's `standard` profile no longer creates content types; the bootstrap script adds Article and Basic page from core recipes.

## Continuous integration

[`.github/workflows/demo-validate.yml`](../.github/workflows/demo-validate.yml) runs on every change to this folder:

| Job | What it checks |
|---|---|
| Static checks | PHP syntax, ShellCheck, Compose config, `composer validate` (lock file in sync), the site-to-database validator's test suite, `helm lint`, and Kubernetes schema validation of the rendered chart with `kubeconform` |
| Docker Compose smoke test | [`tests/compose/smoke.sh`](tests/compose/smoke.sh): builds `app` and `web`, installs both sites from config, then checks: routing by host name; one database per site; config and content don't leak between sites (an article on site A is a 404 on site B); unknown hosts get 404; nginx blocks dotfiles, YAML, PHP sources and private paths; PHP-FPM writes public files that nginx serves; private files work; cron and `drush deploy` run |
| Kubernetes (kind) smoke test | [`tests/k8s/smoke.sh`](tests/k8s/smoke.sh): installs the chart against a test MariaDB with **one database user per site** and checks that `site_a_user` can't read `site_b`. Then checks: both containers run non-root; routing through the Service; public and private files; per-site CronJobs; and that `helm upgrade` runs the per-site `drush deploy` Jobs one after another |
| Ingress and autoscaling (kind) | [`tests/k8s/scaling-ingress.sh`](tests/k8s/scaling-ingress.sh): installs metrics-server and Traefik (a stand-in for the ALB), routes both host names through the chart's Ingress, and loads site A until the HPA scales out |

## Kubernetes / EKS

The chart's site list is in [`values.yaml`](helm/drupal/values.yaml); keep it in sync with `web/sites/sites.php`. It expects:

- a Secret (`existingSecret`, default `drupal-env`) with `<SITE>_DB_USER`, `<SITE>_DB_PASSWORD` and `<SITE>_HASH_SALT` for every site. On EKS, set `externalSecrets.enabled=true` to have External Secrets create it from Secrets Manager (`<keyPrefix>/<site id>`, properties `db_user`, `db_password`, `hash_salt`);
- a ReadWriteMany claim (`persistence.existingClaim`, default `drupal-files`; EFS on EKS) laid out as `public/<site>` and `private/<site>`;
- immutable image digests for `image.app.digest` and `image.web.digest` (`tag` is only for test clusters).

For a real cluster:

1. Provision EKS, RDS, EFS with the CSI driver, the AWS Load Balancer Controller, External Secrets and Secrets Manager (runbook Phases 12–14).
2. Build and push both targets to ECR, and record their digests.
3. Set `database.host`, the site host names, `trustedProxyIps` (after the Phase 8 proxy tests), and `ingress.enabled=true` with ALB annotations.
4. Review the rendered manifests, then install to non-production:

```bash
helm template drupal helm/drupal -n drupal -f my-values.yaml | less
helm upgrade --install drupal helm/drupal -n drupal --create-namespace -f my-values.yaml
```

Every later `helm upgrade` runs `drush deploy` once per site, in order, as post-upgrade hook Jobs. A failed Job fails the release. Take a verified backup first: a Kubernetes rollback doesn't undo database updates.

## Site-to-database mapping

[`scripts/validate-site-databases.sh`](scripts/validate-site-databases.sh) checks the `site-databases.csv` used by the runbook (Phases 3, 14 and 17). See [`migration/site-databases.example.csv`](migration/site-databases.example.csv) for the format and [`tests/site-databases/`](tests/site-databases/) for the failure cases it catches.

```bash
scripts/validate-site-databases.sh --sites "site_a site_b" migration/site-databases.example.csv
```

## Map to the runbook

| Runbook phases | In this demo |
|---|---|
| 1–4 Discovery, backups | [`docs/DISCOVERY.md`](docs/DISCOVERY.md), site-to-database validator |
| 5–7 Remove BLT | **Not demonstrated:** the demo starts from a Composer project without BLT |
| 8 Settings | `sites.php` for every environment; `settings.shared.php` included at the end of each site's `settings.php` |
| 9–11 Build, local, test | Two-target `Dockerfile`, `compose.yaml`, Compose smoke test |
| 12–14 AWS | AWS services are prerequisites, not created here. Per-site database users are tested on kind |
| 15 Kubernetes workload | Helm chart, tested on kind |
| 16 CI/CD | Validation and smoke tests only; **does not deploy** |
| 17–20 Migrate, cutover | [`docs/CUTOVER.md`](docs/CUTOVER.md) checklist; **not executed** |

## Limitations

- Not run on AWS: EFS, RDS, ALB, External Secrets, IAM and OIDC are untested. The kind test uses a ReadWriteOnce volume on one node; EKS needs ReadWriteMany (EFS).
- No custom theme, so the runbook's Node build stage is left out. Redis is wired up in `settings.shared.php` but disabled: install the `redis` module, then set `REDIS_HOST` and `REDIS_ENABLED=1`.
- Reverse-proxy settings (`trustedProxyIps`) can only be verified behind the real ALB (runbook Phase 8).
- Never commit `.env`, database dumps, private files or secrets. Running EKS, RDS, NAT gateways, EFS and load balancers costs money.
