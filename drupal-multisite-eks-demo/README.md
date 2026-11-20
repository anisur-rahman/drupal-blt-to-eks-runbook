# Drupal Multisite → AWS EKS: Portfolio Demo

**Status: starter implementation; not a completed production migration.** This project accompanies the corrected 20-step *Drupal BLT to EKS Runbook*. It demonstrates a BLT-independent Composer/Drush workflow, two Drupal sites sharing code, separate MariaDB databases, local Docker Compose, and Helm-generated Kubernetes resources. **No Acquia source environment, AWS account, production data, or executed EKS deployment is included.**

## Architecture
Local: hostnames → Apache/PHP Drupal container → separate MariaDB databases.
Proposed EKS: ALB → Drupal pods → RDS; EFS for shared public files; AWS Secrets Manager via External Secrets; ECR for images. Infrastructure provisioning, EFS CSI configuration, and ingress/controller installation are **prerequisites**, not automated by this starter.

## Prerequisites
Docker Desktop + Compose; for cloud, AWS CLI, kubectl, Helm, EKS cluster, ECR, RDS, EFS, and IAM/Pod Identity.

## Local walkthrough (first run)
```bash
cp .env.example .env
# Set non-default passwords in .env for local development.
docker compose build
docker compose up -d
docker compose exec app composer install
docker compose exec app bash scripts/install-local.sh
```
Map hostnames in `/etc/hosts` (or use curl `-H 'Host: site-a.localhost'`):
```
127.0.0.1 site-a.localhost site-b.localhost
```
Open http://site-a.localhost:8080 and http://site-b.localhost:8080.
Site-specific admin credentials are printed by Drush during installation. Change them before any shared environment. The installation script uses a single demo password only for isolated local development.

## Local verification
```bash
docker compose exec app vendor/bin/drush --uri=http://site-a.localhost:8080 status
docker compose exec app vendor/bin/drush --uri=http://site-b.localhost:8080 status
curl -I -H 'Host: site-a.localhost' http://localhost:8080/
curl -I -H 'Host: site-b.localhost' http://localhost:8080/
docker compose logs --tail=50 app
```

## Cloud preparation (not yet deployed)
1. Provision EKS, private RDS databases, EFS access points and CSI driver, AWS Load Balancer Controller, External Secrets Operator and AWS Secrets Manager.
2. Create per-site DB users/secrets, persistent mounts, DNS/TLS, security groups, WAF and backups.
3. Build and push the app image to ECR; use immutable image digest in Helm values.
4. Update `helm/drupal/values.yaml` with actual image, hostnames, storage claim, secret names and database endpoints.
5. Run `helm lint helm/drupal`, `helm template drupal helm/drupal -n drupal`, review manifests.
6. Deploy to non-production only after prerequisites are verified:
```bash
helm upgrade --install drupal helm/drupal --namespace drupal --create-namespace -f helm/drupal/values.yaml
kubectl -n drupal get deploy,svc,cronjob
```
7. Run per-site Drush deploy **sequentially** with the release image, maintenance controls and backups. See `scripts/deploy-sites.sh`; it assumes a running Drupal pod and must be adapted to the organization's Job execution model.

## Connection to 20-step runbook
- Steps 1–4: `docs/DISCOVERY.md`, acceptance/evidence templates.
- Steps 5–8: Composer/Drush only; `web/sites/sites.php` and per-site settings; no BLT dependency.
- Steps 9–11: Docker, Compose and local smoke tests.
- Steps 12–15: Helm templates (cluster and supporting AWS services are prerequisites).
- Step 16: GitHub Actions validation/build example; **does not deploy**.
- Steps 17–20: `docs/CUTOVER.md` checklist; **not executed**.

## Security and limitations
Never commit `.env`, DB dumps, private files or secrets. Local demo credentials are **not** production defaults. `ExternalSecret` API is not assumed; check installed CRDs and add a version-matched manifest separately. Helm uses `existingSecret` references. No fabricated screenshots, performance numbers or production claims. EKS, RDS, NAT, EFS and load balancers incur AWS charges.

## Evidence to collect after running
Use `docs/EVIDENCE.md` to record actual command outputs, screenshots, CI links, image digests, load test results, and rollback rehearsal.
