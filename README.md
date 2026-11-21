# Drupal Multisite Modernization: Acquia BLT → AWS EKS

**Reference architecture, migration runbook and tested demo.**

A 20-phase approach to modernizing a Drupal multisite platform: removing the Acquia BLT dependency, moving to Composer and Drush workflows, running the sites in containers, deploying to Amazon EKS with CI/CD, and migrating with rehearsed cutover and rollback. A companion demo puts the core patterns into running code, and CI tests them on every change.

[![Demo – validate, build and smoke test](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/workflows/demo-validate.yml/badge.svg)](https://github.com/anisur-rahman/drupal-blt-to-eks-runbook/actions/workflows/demo-validate.yml)

> **Status: reference design, not a completed production migration.** The Acquia and AWS steps have not been executed against a real Acquia environment or AWS account. The settings, container and Kubernetes patterns have been run locally and on a kind cluster. The runbook's [validation status](RUNBOOK.md#validation-status) table separates the two.

## What's here

| | |
|---|---|
| [`RUNBOOK.md`](RUNBOOK.md) | The runbook: executive summary, target architecture, design decisions, risks, and every phase as commands. Read it here on GitHub. |
| [`Drupal_BLT_to_EKS_Runbook_v5.docx`](Drupal_BLT_to_EKS_Runbook_v5.docx) | The same runbook as a Word document (revision 5). |
| [`drupal-multisite-eks-demo/`](drupal-multisite-eks-demo/) | Two Drupal 11 sites on one codebase without BLT: Docker Compose, a Helm chart, a site-to-database mapping validator, and smoke tests. See its [README](drupal-multisite-eks-demo/README.md). |

## Repository structure

```
.
├── README.md                              This page
├── RUNBOOK.md                             The 20-phase runbook (revision 5)
├── Drupal_BLT_to_EKS_Runbook_v5.docx      The runbook as a Word document
├── .github/workflows/
│   └── demo-validate.yml                  CI: static checks, Compose and Kubernetes smoke tests
└── drupal-multisite-eks-demo/             Working demo: two Drupal 11 sites, one codebase
    ├── README.md                          How to run the demo
    ├── Dockerfile                         Two targets: app (PHP-FPM 8.3, Drupal 11, Drush 13) and web (nginx)
    ├── compose.yaml                       Local stack: app + web (sharing a network, like a pod) + MariaDB
    ├── composer.json, composer.lock       Drupal dependencies, no Acquia BLT
    ├── docker/php, docker/nginx           PHP, PHP-FPM and nginx configuration
    ├── .env.example                       Local database passwords (copy to .env)
    ├── web/sites/
    │   ├── sites.php                      Hostname → site directory map
    │   ├── settings.shared.php            Environment-driven settings shared by all sites
    │   ├── default/settings.php           Returns 404 for unknown hostnames
    │   ├── site_a/settings.php            Sets the site name, includes settings.shared.php
    │   └── site_b/settings.php
    ├── config/site_{a,b}/sync/            Each site's exported configuration, outside public files
    ├── docker/db-init/01-sites.sh         Creates the second site's database locally
    ├── helm/drupal/                       Helm chart
    │   ├── values.yaml                    Image, database, site list, Ingress settings
    │   └── templates/                     Deployment (nginx + PHP-FPM), Service, HPA, PDB, ConfigMap,
    │                                      per-site CronJobs and deploy Jobs, Ingress, ExternalSecret
    ├── migration/
    │   └── site-databases.example.csv     Site → Acquia database → target database mapping
    ├── scripts/
    │   ├── validate-site-databases.sh     Checks the mapping before backups (runbook Phase 3)
    │   ├── bootstrap-config.sh            One-time: creates and exports each site's configuration
    │   ├── install-local.sh               Installs both sites locally from that configuration
    │   └── deploy-sites.sh                Runs drush deploy per site, in order
    ├── tests/
    │   ├── compose/smoke.sh               Docker Compose end-to-end test
    │   ├── k8s/                           Kubernetes (kind) end-to-end, Ingress and autoscaling tests
    │   └── site-databases/                Validator tests and bad-input fixtures
    └── docs/
        ├── EVIDENCE.md                    What was run, where, and the results
        ├── evidence/                      Screenshots and smoke test logs
        ├── ARCHITECTURE.md                Architecture decisions
        ├── DISCOVERY.md                   Discovery checklist (runbook Phases 1–4)
        └── CUTOVER.md                     Cutover checklist (runbook Phases 17–20)
```

## What has been tested

All of this runs in the [CI workflow](.github/workflows/demo-validate.yml). Results and screenshots are in [`EVIDENCE.md`](drupal-multisite-eks-demo/docs/EVIDENCE.md).

- **Images (Phase 9):** one Dockerfile builds `app` (PHP-FPM 8.3, Drupal 11, Drush 13, no BLT) and `web` (unprivileged nginx). Both run as non-root.
- **Multisite on Docker Compose (Phase 10):** both sites install from committed configuration. Each hostname serves its own site from its own database, and config and content don't leak between sites. Unknown hostnames get 404, not the Drupal installer. nginx blocks dotfiles, YAML, PHP sources and private paths. Cron and `drush deploy` run.
- **Helm chart on Kubernetes (kind, Phases 14–15):** nginx + PHP-FPM pods serve both sites through the Service. Each site has its own database user, and one site's user can't read another site's database. Public and private files are writable. Each site's CronJob runs, and `helm upgrade` runs `drush deploy` once per site, in order. The rendered manifests pass `kubeconform` schema validation.
- **Ingress and autoscaling (kind):** the chart's Ingress routes both hostnames (Traefik stands in for the ALB), and the HPA scales out under load with metrics-server.
- **Migration inventory:** the `site-databases.csv` validator passes on valid input and rejects 9 kinds of bad input.

Building and running the demo turned up 18 defects that static checks had missed. Three were in the runbook's own Phase 8–9 templates; for example, PHP-FPM's default `clear_env` would have hidden every environment variable from the settings. All 18 are listed in [`EVIDENCE.md`](drupal-multisite-eks-demo/docs/EVIDENCE.md#defects-found-by-running-the-demo).

## The runbook's phases

| Phases | Topic |
|--------|-------|
| 1–4 | [Inventory, baseline, backup and acceptance criteria](RUNBOOK.md#phases-14-inventory-baseline-backup-acceptance) |
| 5–8 | [Remove BLT and refactor settings for containers](RUNBOOK.md#phases-58-remove-blt-and-refactor-settings) |
| 9–11 | [Build the production image, run locally, test and scan](RUNBOOK.md#phases-911-build-run-locally-test) |
| 12–14 | [AWS landing zone, EKS, RDS, EFS, Redis and secrets](RUNBOOK.md#phases-1214-aws-landing-zone-eks-and-supporting-services) |
| 15 | [Kubernetes workload: Deployment, HPA, Ingress, update Job, CronJob](RUNBOOK.md#phase-15-kubernetes-workload) |
| 16 | [CI/CD pipeline with GitHub Actions, OIDC, ECR and EKS](RUNBOOK.md#phase-16-cicd-pipeline) |
| 17–18 | [Migrate data, rehearse and validate](RUNBOOK.md#phases-1718-migrate-data-rehearse-validate) |
| 19–20 | [Cutover, rollback and decommission](RUNBOOK.md#phases-1920-cutover-rollback-decommission) |
| After cutover | [Drupal 11 upgrade and a daily command cheat sheet](RUNBOOK.md#after-cutover-drupal-11-and-daily-commands) |

## Stack

Drupal 11 multisite · Composer · Drush · Docker · Helm · Kubernetes · Amazon EKS · ECR · RDS (MySQL) · EFS · ElastiCache (Redis) · ALB · CloudFront · WAF · External Secrets · GitHub Actions (OIDC)

## Using the runbook

1. Copy the `migration.env` block from [Conventions and prerequisites](RUNBOOK.md#conventions-and-prerequisites) and replace the example values.
2. Work through the phases in order on a non-production clone first, collecting the evidence listed in [Production readiness gates](RUNBOOK.md#production-readiness-gates).

All values in this repo are placeholders: AWS account `123456789012`, domains under `example.org`, GitHub org `myorg`. Don't commit real account IDs, hostnames, certificate ARNs, inventories or backups to a fork.

## Author

Md Anisur Rahman
