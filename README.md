# Drupal Multisite: Acquia BLT → AWS EKS Runbook

A step-by-step command runbook for moving a Drupal multisite from Acquia Cloud with BLT to a container platform on Amazon EKS. It covers the whole path: inventory and backups, removing BLT, container-ready settings, the AWS landing zone, Kubernetes manifests, CI/CD with GitHub Actions (OIDC), data migration, cutover, rollback and the Drupal 11 upgrade.

> **Status: reference design.** This runbook is a proposed implementation, not a record of a completed migration. All commands are examples that need validation in your own environment. Start on a non-production clone, and record evidence, approvals and rollback checkpoints before each destructive step.

## Files

| File | Description |
|------|-------------|
| [`RUNBOOK.md`](RUNBOOK.md) | The full runbook. Read it here on GitHub. |
| [`Drupal_BLT_to_EKS_Runbook_v4.docx`](Drupal_BLT_to_EKS_Runbook_v4.docx) | The same content as a Word document (revision 4). |
| [`drupal-multisite-eks-demo/`](drupal-multisite-eks-demo/) | A starter project that applies the runbook: two Drupal 11 sites without BLT, Docker Compose for local runs, and a Helm chart for EKS. See its own [README](drupal-multisite-eks-demo/README.md). |

## What's covered

The runbook is organised into 20 phases:

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

Drupal 10/11 multisite · Composer · Drush · Docker · Amazon EKS · ECR · RDS (MySQL) · EFS · ElastiCache (Redis) · ALB · CloudFront · WAF · External Secrets · Helm · eksctl · GitHub Actions

## Using it

1. Copy the `migration.env` block from [Conventions and prerequisites](RUNBOOK.md#conventions-and-prerequisites) and replace the example values with your own.
2. Run `source migration.env` in each shell before running any commands.
3. Work through the phases in order on a non-production clone first.

All values in this repo are placeholders: AWS account `123456789012`, domains under `example.org`, and the GitHub org `myorg`. Don't commit real account IDs, hostnames, certificate ARNs, inventories or backups to a fork.

## Author

Md Anisur Rahman
