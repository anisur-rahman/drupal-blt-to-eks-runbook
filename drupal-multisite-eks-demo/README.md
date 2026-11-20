# Drupal Multisite → AWS EKS: Demo

**Status: working starter, tested locally and on a kind cluster; not deployed to AWS.** This project accompanies the [BLT to EKS runbook](../RUNBOOK.md). It shows two Drupal 11 sites sharing one codebase with separate databases, no Acquia BLT dependency, a Docker Compose setup for local work, and a Helm chart for Kubernetes. No Acquia environment, AWS account or production data is involved.

What is proven, and how, is in [`docs/EVIDENCE.md`](docs/EVIDENCE.md).

## Architecture

- **Local:** hostname → Apache + PHP 8.3 container → `sites.php` picks the site → MariaDB, one database per site.
- **Kubernetes (chart):** Service → Drupal pods (Deployment + HPA) → database; one CronJob per site; a persistent volume for public files; optional Ingress.
- **EKS target (runbook):** ALB → pods → RDS; EFS for files; Secrets Manager via External Secrets; images in ECR. Provisioning these is a prerequisite and not automated here.

Unknown hostnames get a 404 instead of Drupal's installer (`web/sites/default/settings.php`).

## Run it locally

Needs Docker with Compose v2.

```bash
tests/compose/smoke.sh
```

This builds the image, starts the stack, installs both sites with random admin passwords, and checks routing, database isolation and cron. Then open the sites:

```bash
echo "127.0.0.1 site-a.localhost site-b.localhost" | sudo tee -a /etc/hosts   # if they don't resolve
open http://site-a.localhost:8080 http://site-b.localhost:8080
```

Or do it step by step:

```bash
cp .env.example .env               # then set your own passwords in .env
docker compose up -d --build --wait
docker compose exec app bash scripts/install-local.sh
docker compose exec app vendor/bin/drush --uri=http://site-a.localhost:8080 status
curl -I -H 'Host: site-b.localhost' http://localhost:8080/
```

`install-local.sh` uses a fixed demo admin password for isolated local use only. Clean up with `docker compose down -v`.

## Continuous integration

[`.github/workflows/demo-validate.yml`](../.github/workflows/demo-validate.yml) runs on every change to this folder:

| Job | What it checks |
|---|---|
| Static checks | PHP syntax, ShellCheck, Compose config, the site-to-database validator's test suite, `helm lint`, and Kubernetes schema validation of the rendered chart with `kubeconform` |
| Docker Compose smoke test | [`tests/compose/smoke.sh`](tests/compose/smoke.sh): builds the image, installs both sites, then checks each hostname serves its own site, each site uses its own database, config changes don't leak between sites, unknown hosts get 404, the config sync directory is outside public files, and cron runs |
| Kubernetes (kind) smoke test | [`tests/k8s/smoke.sh`](tests/k8s/smoke.sh): creates a kind cluster, installs the Helm chart against a test MariaDB, installs both sites in the pod, checks routing through the Service, file-volume writes, and runs each site's CronJob |

## Kubernetes / EKS

The chart in [`helm/drupal`](helm/drupal) takes its site list from `values.yaml` (keep it in sync with `web/sites/sites.php`). For a real cluster:

1. Provision EKS, RDS, EFS with the CSI driver, the AWS Load Balancer Controller, External Secrets and Secrets Manager (runbook Phases 12–14).
2. Create the database secret (`database.existingSecret`, key `password`) and a ReadWriteMany claim (`persistence.existingClaim`).
3. Push the image to ECR and set `image.digest` to its immutable digest. `image.tag` exists only for test clusters.
4. Set `database.host`, the site hostnames, and `ingress.enabled=true` with ALB annotations.
5. Review the rendered manifests, then install to non-production:

```bash
helm template drupal helm/drupal -n drupal -f my-values.yaml | less
helm upgrade --install drupal helm/drupal -n drupal --create-namespace -f my-values.yaml
```

6. Run `drush deploy` per site, one at a time, with a verified backup ([`scripts/deploy-sites.sh`](scripts/deploy-sites.sh) shows the order; adapt it to a Kubernetes Job).

## Site-to-database mapping

[`scripts/validate-site-databases.sh`](scripts/validate-site-databases.sh) checks the `site-databases.csv` used by the runbook (Phases 3, 14 and 17). See [`migration/site-databases.example.csv`](migration/site-databases.example.csv) for the format and [`tests/site-databases/`](tests/site-databases/) for the failure cases it catches.

```bash
scripts/validate-site-databases.sh --sites "site_a site_b" migration/site-databases.example.csv
```

## Map to the runbook

| Runbook phases | In this demo |
|---|---|
| 1–4 Discovery, backups | [`docs/DISCOVERY.md`](docs/DISCOVERY.md), site-to-database validator |
| 5–8 Remove BLT, settings | Composer + Drush only; env-driven per-site `settings.php`; `sites.php` for every environment |
| 9–11 Build, local, test | `Dockerfile`, `compose.yaml`, Compose smoke test |
| 12–15 AWS and Kubernetes | Helm chart, tested on kind. AWS services are prerequisites, not created here |
| 16 CI/CD | Validation and smoke tests only; **does not deploy** |
| 17–20 Migrate, cutover | [`docs/CUTOVER.md`](docs/CUTOVER.md) checklist; **not executed** |

## Limitations

- The image is a single Apache + PHP container for simplicity. The runbook's production design uses separate nginx and PHP-FPM images.
- The chart has no External Secrets, PodDisruptionBudget or per-release deploy Job yet; it reads an existing Secret.
- The kind test uses a ReadWriteOnce volume on one node. EKS needs ReadWriteMany (EFS).
- Private files go to `/tmp` in the container; production needs a dedicated mount.
- Never commit `.env`, database dumps, private files or secrets. Running EKS, RDS, NAT gateways, EFS and load balancers costs money.
