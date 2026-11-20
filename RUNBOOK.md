# Drupal Multisite: Acquia BLT → AWS EKS — Comparison & Full Command Runbook

Nov 20, 2026 · Md Anisur Rahman

## Comparison: your EKS guide vs the generic process

Your guide is stronger on governance: acceptance criteria, landing zone, compliance, load testing and a realistic rollback. The generic process is stronger on the actual mechanics: settings refactor, Drush deploy, cron and the Acquia-only modules. This runbook merges both and keeps your 20-step numbering.

| Area                                                  | Your EKS guide                                              | Generic process                                                                            | Used in this runbook                                                         |
|-------------------------------------------------------|-------------------------------------------------------------|--------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| Target platform                                       | AWS EKS, ECR, RDS, EFS/S3, Redis, ALB, CloudFront, WAF      | Platform-neutral (Kubernetes, ECS or VM)                                                   | EKS, as in your guide                                                        |
| Docroot                                               | `web/`                                                      | `docroot/` (Acquia default)                                                                | `web/`; see the note in Conventions if yours is still `docroot/`             |
| Inventory and acceptance criteria                     | Detailed (owners, SLOs, RPO/RTO, go/no-go)                  | Brief                                                                                      | Yours                                                                        |
| BLT removal                                           | `composer remove --dev acquia/blt` only                     | Also removes the `blt.settings.php` require from each site and adds a settings replacement | Both. BLT is usually in `require`, not `require-dev`, so `--dev` can miss it |
| Settings for containers                               | "Externalize via env/secrets" (no code)                     | Shared env-driven settings file per site                                                   | Full file given in Phase 8                                                   |
| Acquia-only modules (connector, purge, search)        | Not mentioned                                               | Uninstall or replace before cutover                                                        | Added in Phase 8                                                             |
| Reverse proxy, trusted hosts, hash salt behind an ALB | Not mentioned                                               | Covered                                                                                    | Added                                                                        |
| Running Drupal updates                                | `updatedb`, `config:import`, `cache:rebuild` run separately | `drush deploy` per site                                                                    | `drush deploy`: same steps in the correct order, plus deploy hooks           |
| Where updates run on EKS                              | Not specified                                               | Not specified                                                                              | A one-off Kubernetes Job per release, so updates don't run in every pod      |
| Cron                                                  | "Verify scheduled tasks"                                    | Per-site cron loop                                                                         | A Kubernetes CronJob                                                         |
| Backups                                               | `drush sql:dump` on the local copy                          | `sql:dump` against the Acquia alias                                                        | Acquia CLI backups + Drush against the remote alias, plus files              |
| AWS provisioning                                      | Described; commands only for kubeconfig                     | Not covered                                                                                | Full CLI commands (eksctl, aws, helm)                                        |
| Kubernetes manifests                                  | `kubectl apply -f k8s/` only                                | Not covered                                                                                | Full manifests                                                               |
| CI/CD                                                 | Described; docker tag/push only                             | GitHub Actions example                                                                     | GitHub Actions with OIDC to ECR and EKS                                      |
| Load, accessibility and security testing              | Covered                                                     | Not covered                                                                                | Yours, with commands                                                         |
| Rollback                                              | Notes that a Kubernetes rollback can't undo schema updates  | DNS rollback window                                                                        | Both                                                                         |
| Drupal 11 upgrade (Drupal 10 support ends 9 Dec 2026) | Not mentioned                                               | Covered                                                                                    | Added at the end                                                             |

**Fixes to your guide's commands:**

- Step 3 dumps the *local* database. Run the dump against the Acquia alias (`drush @prod.site_a sql:dump`) or use `acli` backups, and copy the files too.
- Step 7: `composer remove --dev acquia/blt` does nothing if BLT is in `require`. Check first with `composer show -D | grep blt`.
- Step 17 omits `deploy:hook`. `drush deploy` covers it.
- Step 1 uses `find web/sites` while Acquia projects start with `docroot/`. Confirm which one you have.

## Conventions and prerequisites

Every command below assumes the variables in this file. Source it in each shell (`source migration.env`) and replace the example values with your own.

    # migration.env
    export AWS_REGION=us-east-1
    export AWS_ACCOUNT_ID=123456789012
    export CLUSTER=drupal-prod
    export NS=drupal
    export ECR_REPO=drupal-multisite
    export ECR=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
    export DOCROOT=web                 # or docroot if you keep Acquia's layout
    export SITES="site_a site_b site_c" # directory names under $DOCROOT/sites
    export ACQUIA_APP=myorg.myapp      # Acquia application name
    export ACQUIA_ENV=prod
    export GIT_SHA=$(git rev-parse --short HEAD)

**Tools to install on your workstation:**

    # macOS (Homebrew); use your distro's packages on Linux
    brew install awscli eksctl kubectl helm terraform jq git php@8.3 composer
    brew install --cask docker
    curl -OL https://github.com/acquia/cli/releases/latest/download/acli.phar \
      && chmod +x acli.phar && sudo mv acli.phar /usr/local/bin/acli
    brew install ddev/ddev/ddev    # optional, for local dev

    aws --version && eksctl version && kubectl version --client && helm version
    acli auth:login
    aws sts get-caller-identity

**Site loop helper:** many steps repeat per site. This function runs a Drush command for every site:

    forsites() { for s in $SITES; do echo "== $s"; vendor/bin/drush -l "$s" "$@" || return 1; done; }
    # usage: forsites status

**REVIEWED IMPLEMENTATION NOTE — Execution status**

REFERENCE RUNBOOK / PROPOSED IMPLEMENTATION — commands are examples requiring environment-specific validation. No live Acquia migration, AWS provisioning, restore, benchmark or production cutover is asserted. Use a non-production clone first. Record evidence, approvals, and rollback checkpoints before each destructive step.

**Revision 4 corrections:** the BLT settings include is now removed before `composer remove`; BLT is removed with `--minimal-changes`; `TRUSTED_PROXY_IPS` is set to the ALB public subnet CIDRs in the ConfigMap; local file restores use `local-files/`; Phase 14 database and user names come from `site-databases.csv`; `patches/` is guaranteed to exist; the Phase 8 loop no longer calls `exit`; and the first apply scales to the HPA minimum.

## Phases 1–4: Inventory, baseline, backup, acceptance

### 1. Inventory sites and BLT usage

    git clone git@github.com:myorg/drupal-platform.git && cd drupal-platform
    mkdir -p migration/inventory

    # Site directories and domain mapping
    find $DOCROOT/sites -maxdepth 2 -name settings.php | sort | tee migration/inventory/settings-files.txt
    grep -E '^\s*\$sites\[' $DOCROOT/sites/sites.php | tee migration/inventory/sites-map.txt

    # Everything BLT and Acquia touch
    find . -path ./vendor -prune -o \( -iname '*blt*' -o -name 'acquia-pipelines.yml' \) -print | tee migration/inventory/blt-files.txt
    ls hooks/ factory-hooks/ 2>/dev/null | tee migration/inventory/cloud-hooks.txt
    cat blt/blt.yml | tee migration/inventory/blt.yml.txt
    grep -rn "blt\.settings\.php\|acquia" $DOCROOT/sites/*/settings.php | tee migration/inventory/settings-refs.txt
    grep -rn "blt " .github .gitlab-ci.yml acquia-pipelines.yml composer.json scripts 2>/dev/null | tee migration/inventory/blt-commands.txt

    # Packages
    composer show -D | tee migration/inventory/direct-packages.txt
    composer show | grep -Ei "acquia|blt|drush|drupal/core" | tee migration/inventory/acquia-packages.txt

    # Per-site modules (finds acquia_connector, acquia_purge, acquia_search, memcache)
    for s in $SITES; do
      vendor/bin/drush -l $s pm:list --status=enabled --type=module --format=list > migration/inventory/modules-$s.txt
      grep -E "acquia|memcache|purge|search_api" migration/inventory/modules-$s.txt
    done

### 2. Baseline the live environment

    acli remote:aliases:download            # writes drush/sites/<app>.site.yml
    vendor/bin/drush site:alias | grep $ACQUIA_ENV

    for s in $SITES; do
      acli remote:drush $ACQUIA_APP.$ACQUIA_ENV -- -l $s status --format=json > migration/inventory/status-$s.json
      acli remote:drush $ACQUIA_APP.$ACQUIA_ENV -- -l $s config:status   # must be clean
      acli remote:drush $ACQUIA_APP.$ACQUIA_ENV -- -l $s core:requirements --severity=2
    done

    git rev-parse HEAD > migration/inventory/baseline-commit.txt
    composer validate --strict

    # Performance baseline per domain (repeat for each)
    curl -s -o /dev/null -w "%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n" https://site-a.example.org/

### 3. Back up and prove a restore

    # Preserve a separate full archival backup. The optimized migration dump below intentionally omits configured disposable tables (e.g. cache/search), but verify table lists and session/history requirements before use.
    mkdir -p backups/$(date +%F)
    # Acquia-managed backups (one DB per site)
    acli api:environments:database-list $ACQUIA_APP.$ACQUIA_ENV
    # Record verified site-to-Acquia-database mapping in migration/inventory/site-databases.csv.
    # Example columns: site,acquia_database,target_database; do not assume names match.
    # Validate mapping against Acquia CLI output before initiating backups.
    while IFS=, read -r site acquia_db target_db; do
      [ "$site" = site ] && continue
      acli api:environments:database-backup-create "$ACQUIA_APP.$ACQUIA_ENV" "$acquia_db"
    done < migration/inventory/site-databases.csv

    # Portable copies
    for s in $SITES; do
      vendor/bin/drush @$ACQUIA_APP.$ACQUIA_ENV -l $s sql:dump --gzip --structure-tables-key=common \
        > backups/$(date +%F)/$s.sql.gz
      vendor/bin/drush rsync @$ACQUIA_APP.$ACQUIA_ENV:%files/ backups/$(date +%F)/$s-files/ -l $s -y
      vendor/bin/drush rsync @$ACQUIA_APP.$ACQUIA_ENV:%private/ backups/$(date +%F)/$s-private/ -l $s -y
    done
    sha256sum backups/$(date +%F)/*.sql.gz > backups/$(date +%F)/SHA256SUMS

    # Restore test into an isolated DB
    docker run -d --name restoretest -e MARIADB_ROOT_PASSWORD=root -p 3307:3306 mariadb:10.11
    sleep 20 && mysql -h127.0.0.1 -P3307 -uroot -proot -e "CREATE DATABASE site_a"
    gunzip -c backups/$(date +%F)/site_a.sql.gz | mysql -h127.0.0.1 -P3307 -uroot -proot site_a
    mysql -h127.0.0.1 -P3307 -uroot -proot site_a -e "SELECT COUNT(*) FROM node_field_data"
    docker rm -f restoretest

### 4. Acceptance criteria

No commands here. Write a `migration/ACCEPTANCE.md` with each hostname and its owner, key user journeys, SLOs (for example p95 TTFB under 800 ms), RPO/RTO, the change-freeze window and the go/no-go checklist. Phase 18 tests against it.

**REVIEWED IMPLEMENTATION NOTE — Backups and data integrity**

For migration backups, do not use a structure-only table exclusion unless explicitly approved and verified. Inventory actual Acquia database names rather than assuming they match site directory names. Capture complete DB, public/private files and configuration; encrypt backups, restrict access, checksum, and perform a full isolated restore including functional verification. Avoid putting production data or secrets in Git.

## Phases 5–8: Remove BLT and refactor settings

### 5. Map BLT tasks to replacements

| BLT command                                      | Replacement                                                       |
|--------------------------------------------------|-------------------------------------------------------------------|
| `blt setup` / `blt drupal:install`               | `drush -l <site> site:install --existing-config -y`               |
| `blt drupal:update` / `blt drupal:deploy:update` | `drush -l <site> deploy -y`                                       |
| `blt sync` / `blt drupal:sync:db`                | `drush sql:sync @src @self -l <site>` + `drush rsync`             |
| `blt source:build:composer`                      | `composer install --no-dev -o`                                    |
| `blt source:build:frontend`                      | `npm ci && npm run build` (in the theme)                          |
| `blt validate:phpcs`                             | `vendor/bin/phpcs`                                                |
| `blt tests:phpunit`                              | `vendor/bin/phpunit`                                              |
| `blt artifact:deploy`                            | CI builds and pushes a Docker image to ECR                        |
| `blt recipes:multisite:init`                     | Create the site directory and `sites.php` entry by hand (Phase 8) |
| BLT git hooks                                    | GrumPHP: `composer require --dev phpro/grumphp`                   |
| Cloud Hooks (`hooks/common/post-code-deploy`)    | Kubernetes Job in Phase 15                                        |

### 6. Create the migration branch

    git checkout -b migration/remove-acquia-blt
    composer validate --strict
    composer install --no-interaction
    forsites status --field=bootstrap      # every site must say "Successful"

### 7. Remove BLT

    # Is BLT in require or require-dev?
    composer show -D | grep -i blt
    jq '.require, ."require-dev"' composer.json | grep -i blt

    # Remove the BLT include from each site's settings.php BEFORE removing the package.
    # Otherwise every site fatals on the missing vendor/acquia/blt/settings/blt.settings.php.
    # Only the BLT require line is commented out; every other site setting is kept.
    grep -ln "blt.settings.php" $DOCROOT/sites/*/settings.php
    for s in $SITES; do
      f="$DOCROOT/sites/$s/settings.php"
      [ -f "$f" ] || { echo "MISSING: $f"; continue; }
      grep -n 'blt.settings.php' "$f" || continue
      sed -i.pre-blt 's#^\(\s*require.*acquia/blt/settings/blt\.settings\.php.*\)$#// Removed with BLT: \1#' "$f"
      git diff -- "$f"        # review: only the BLT require line changed
      php -l "$f"
    done
    # Anything BLT's settings provided that a site still needs (config sync path, local
    # settings includes, DB credentials) moves into settings.shared.php (Phase 8) first.
    forsites status --field=bootstrap     # every site must still bootstrap
    rm -f $DOCROOT/sites/*/settings.php.pre-blt

    # Remove the package only after every BLT task has a tested replacement (Phase 5).
    # --minimal-changes (Composer 2.7+) removes acquia/blt and the dependencies only it
    # needed, without a full dependency update.
    composer remove acquia/blt --minimal-changes
    # If it is declared in require-dev instead:
    # composer remove --dev acquia/blt --minimal-changes
    # Review each acquia/blt-* plugin and remove it the same way once it is unused.
    # BLT may have been what pulled in Drush:
    composer show drush/drush || composer require drush/drush:^13 --minimal-changes
    composer validate --strict
    git diff composer.lock | head -100    # review the lock file changes

    # Remove the BLT folders after porting any custom commands from blt/src
    git rm -r blt/ acquia-pipelines.yml 2>/dev/null
    rm -f .git/hooks/pre-commit .git/hooks/commit-msg
    composer validate --strict
    grep -rn "blt" composer.json $DOCROOT/sites/ && echo "BLT references remain" || echo "clean"

**Optional: move** `docroot/` **to** `web/`**.** Do this as its own commit.

    git mv docroot web
    jq '.extra["drupal-scaffold"].locations["web-root"]="web/"' composer.json > c.json && mv c.json composer.json
    sed -i 's#"docroot/#"web/#g' composer.json     # installer-paths
    composer install && export DOCROOT=web

### 8. Multisite routing and container-ready settings

`$DOCROOT/sites/sites.php` maps every hostname (production, staging and local) to a site directory:

    <?php
    foreach ([
      'site_a' => ['site-a.example.org', 'site-a.stg.example.org', 'site-a.ddev.site'],
      'site_b' => ['site-b.example.org', 'site-b.stg.example.org', 'site-b.ddev.site'],
    ] as $dir => $hosts) {
      foreach ($hosts as $h) { $sites[$h] = $dir; }
    }

Each site's `settings.php` becomes three lines:

    # Do NOT overwrite site settings.php. Preserve site-specific overrides.
    # Create settings.shared.php separately and add the include to each existing
    # settings.php through a reviewed patch, after its current settings are inventoried.
    for s in $SITES; do
      [ -f "$DOCROOT/sites/$s/settings.php" ] || { echo "MISSING: $s"; continue; }
      grep -n 'settings.shared.php' "$DOCROOT/sites/$s/settings.php" ||     echo "PATCH REQUIRED: $DOCROOT/sites/$s/settings.php"
      mkdir -p "config/$s/sync"
    done
    # Reviewed patch: append these two lines to the END of each site's settings.php, so the
    # environment values in settings.shared.php override older hardcoded ones:
    #   $site_name = 'site_a';
    #   require DRUPAL_ROOT . '/sites/settings.shared.php';
    # Verify with git diff, php -l and Drush bootstrap for every site.

`$DOCROOT/sites/settings.shared.php` reads everything from environment variables injected by Kubernetes:

    <?php
    $env = getenv('APP_ENV') ?: 'local';
    $p = strtoupper($site_name);

    $databases['default']['default'] = [
      'driver' => 'mysql', 'prefix' => '', 'collation' => 'utf8mb4_general_ci',
      'host' => getenv('DB_HOST'), 'port' => getenv('DB_PORT') ?: '3306',
      'database' => getenv("{$p}_DB_NAME") ?: $site_name,
      'username' => getenv("{$p}_DB_USER") ?: getenv('DB_USER'),
      'password' => getenv("{$p}_DB_PASSWORD") ?: getenv('DB_PASSWORD'),
    ];

    $settings['hash_salt'] = getenv("{$p}_HASH_SALT");
    $settings['config_sync_directory'] = "../config/{$site_name}/sync";
    $settings['file_public_path'] = "sites/{$site_name}/files";
    $settings['file_private_path'] = "/mnt/private/{$site_name}";
    $settings['file_temp_path'] = '/tmp';
    $settings['trusted_host_patterns'] = array_filter(explode(',', getenv("{$p}_TRUSTED_HOSTS") ?: ''));
    $settings['update_free_access'] = FALSE;

    // Behind ALB / CloudFront
    $settings['reverse_proxy'] = TRUE;
    // TRUSTED_PROXY_IPS = the ALB's public subnet CIDRs (set in the drupal-config ConfigMap).
    // ALB node IPs change, so subnets are trusted, not single IPs; never REMOTE_ADDR or the whole VPC.
    $settings['reverse_proxy_addresses'] = array_filter(array_map('trim', explode(',', getenv('TRUSTED_PROXY_IPS') ?: '')));
    if (!$settings['reverse_proxy_addresses']) { $settings['reverse_proxy'] = FALSE; }
    $settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR
      | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO
      | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT;

    // Redis (ElastiCache) when the module is enabled
    if (getenv('REDIS_HOST') && file_exists(DRUPAL_ROOT . '/modules/contrib/redis')) {
      $settings['redis.connection']['interface'] = 'PhpRedis';
      $settings['redis.connection']['host'] = getenv('REDIS_HOST');
      $settings['cache_prefix'] = $site_name . '_';
      $settings['cache']['default'] = 'cache.backend.redis';
      $settings['container_yamls'][] = 'modules/contrib/redis/example.services.yml';
    }

    // Config split per environment
    $config['config_split.config_split.local']['status'] = $env === 'local';
    $config['config_split.config_split.prod']['status']  = $env === 'prod';

    if (file_exists(__DIR__ . "/settings.{$env}.php")) { include __DIR__ . "/settings.{$env}.php"; }

Replace Acquia-only modules. `acquia_purge` is still needed while traffic is on Acquia, so disable it through a config split that is only active on Acquia, or uninstall at cutover.

    composer require drupal/redis drupal/purge drupal/cloudfront_purger drupal/search_api_solr drupal/s3fs
    for s in $SITES; do
      vendor/bin/drush -l $s pm:enable redis purge purge_processor_cron purge_queuer_coretags -y
      vendor/bin/drush -l $s pm:uninstall acquia_connector acquia_search memcache -y 2>/dev/null
      vendor/bin/drush -l $s config:export -y
    done
    git add -A && git commit -m "Remove Acquia BLT; env-driven multisite settings"

**REVIEWED IMPLEMENTATION NOTE — Safe BLT and settings refactor**

Do not run the blanket settings.php overwrite shown below against an existing site. Preserve each existing site settings.php, review BLT include dependencies and custom environment settings, and introduce settings.shared.php via a reviewed patch. Remove BLT only from the Composer section where installed; avoid broad composer update -W unless dependency resolution requires it. Keep existing deploy hooks until their replacements are tested. Never uninstall Acquia modules before dependency and cutover checks.

## Phases 9–11: Build, run locally, test

### 9. Production container

One Dockerfile produces two images: `app` (PHP-FPM with code) and `web` (Nginx with the static assets). They run side by side in each pod.

    # Dockerfile
    FROM composer:2 AS vendor
    WORKDIR /app
    COPY composer.json composer.lock ./
    # patches/ must exist in the repo (commit patches/.gitkeep if you have no patches)
    COPY patches/ patches/
    RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-progress
    COPY . .
    RUN composer install --no-dev --optimize-autoloader --no-progress

    FROM node:20-alpine AS theme
    WORKDIR /theme
    COPY web/themes/custom/mytheme/package*.json ./
    RUN npm ci
    COPY web/themes/custom/mytheme/ ./
    RUN npm run build

    FROM php:8.3-fpm-alpine AS app
    RUN apk add --no-cache mysql-client rsync bash icu-libs libpng libjpeg-turbo freetype libzip \
     && apk add --no-cache --virtual .build $PHPIZE_DEPS icu-dev libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev \
     && docker-php-ext-configure gd --with-freetype --with-jpeg \
     && docker-php-ext-install -j$(nproc) pdo_mysql gd opcache intl zip \
     && pecl install redis apcu && docker-php-ext-enable redis apcu && apk del .build
    COPY docker/php/*.ini /usr/local/etc/php/conf.d/
    WORKDIR /var/www/html
    COPY --from=vendor --chown=www-data:www-data /app ./
    COPY --from=theme --chown=www-data:www-data /theme/dist web/themes/custom/mytheme/dist
    ENV PATH="/var/www/html/vendor/bin:${PATH}"
    # www-data numeric UID for runAsNonRoot
    USER 82:82
    # Liveness is checked by Kubernetes probes (Phase 15)

    # Unprivileged NGINX image (verify UID in pinned version)
    FROM nginxinc/nginx-unprivileged:1.27-alpine AS web
    COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
    COPY --from=app /var/www/html/web /var/www/html/web
    mkdir -p docker/php docker/nginx patches && touch patches/.gitkeep
    cat > docker/php/drupal.ini <<'EOF'
    memory_limit=512M
    upload_max_filesize=64M
    post_max_size=64M
    opcache.memory_consumption=256
    opcache.max_accelerated_files=20000
    opcache.validate_timestamps=0
    expose_php=Off
    EOF

    cat > docker/nginx/default.conf <<'EOF'
    server {
      listen 8080;
      root /var/www/html/web;
      index index.php;
      client_max_body_size 64m;
      location = /healthz { access_log off; return 200 "ok"; }
      location ~ ^/sites/.*/private/ { return 403; }
      location ~ (^|/)\. { return 403; }
      location / { try_files $uri /index.php?$query_string; }
      location ~ /sites/[^/]+/files/styles/ { try_files $uri @drupal; }
      location @drupal { rewrite ^ /index.php; }
      location ~ \.php(/|$) {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS $http_x_forwarded_proto if_not_empty;
        fastcgi_pass 127.0.0.1:9000;
      }
    }
    EOF

    cat > .dockerignore <<'EOF'
    .git
    vendor
    node_modules
    web/sites/*/files
    backups
    migration
    *.sql*
    .env*
    EOF

    docker build --target app -t $ECR_REPO:app-dev .
    docker build --target web -t $ECR_REPO:web-dev .
    docker run --rm $ECR_REPO:app-dev php -v
    docker run --rm $ECR_REPO:app-dev php -m | grep -E "pdo_mysql|gd|redis|opcache"
    docker run --rm $ECR_REPO:app-dev drush --version

Both images use `/var/www/html`, so Nginx and PHP-FPM resolve the same paths. In a pod, `fastcgi_pass 127.0.0.1:9000` reaches the `app` container, and both containers mount the same EFS volume at `web/sites/<site>/files`.

### 10. Local stack with Docker Compose

    # Bind-mount only public files, never the entire web/sites tree; site settings remain in the image. Generate mounts from canonical site inventory for >2 sites.
    # compose.yaml
    services:
      app:
        build: { context: ., target: app }
        env_file: .env.local
        volumes: [ "./local-files/site_a:/var/www/html/web/sites/site_a/files", "./local-files/site_b:/var/www/html/web/sites/site_b/files", "./config:/var/www/html/config", "private:/mnt/private" ]
        depends_on: [db, redis]
      web:
        build: { context: ., target: web }
        network_mode: "service:app"   # shares localhost with php-fpm, like a pod
      db:
        image: mariadb:10.11
        environment: { MARIADB_ROOT_PASSWORD: root }
        volumes: [ "db:/var/lib/mysql", "./docker/db-init:/docker-entrypoint-initdb.d" ]
      redis:
        image: redis:7-alpine
    volumes: { db: {}, private: {} }

Publish port 8080 on `app` (`ports: ["8080:8080"]`), because `web` shares its network.

    # LOCAL DEVELOPMENT ONLY: demo drupal/drupal credentials and permissive trusted hosts are prohibited in staging/production.
    mkdir -p docker/db-init
    for s in $SITES; do echo "CREATE DATABASE IF NOT EXISTS $s; GRANT ALL ON $s.* TO 'drupal'@'%' IDENTIFIED BY 'drupal';"; done \
      > docker/db-init/01-dbs.sql

    cat > .env.local <<EOF
    APP_ENV=local
    DB_HOST=db
    DB_USER=drupal
    DB_PASSWORD=drupal
    REDIS_HOST=redis
    EOF
    for s in $SITES; do S=$(echo $s | tr a-z A-Z); echo "${S}_HASH_SALT=$(openssl rand -hex 32)"; echo "${S}_TRUSTED_HOSTS=.*"; done >> .env.local

    docker compose up -d --build
    docker compose ps
    docker compose logs --tail=100 app

    # Load each site from the backups taken in Phase 3
    for s in $SITES; do
      gunzip -c backups/<date>/$s.sql.gz | docker compose exec -T db mysql -uroot -proot $s
      mkdir -p local-files/$s && rsync -a backups/<date>/$s-files/ local-files/$s/
      docker compose exec app drush -l $s deploy -y
    done

    # Check host-based routing without DNS
    for h in site-a.example.org site-b.example.org; do
      curl -s -o /dev/null -w "$h %{http_code}\n" -H "Host: $h" http://localhost:8080/
    done
    docker compose exec app drush -l site_a cron

### 11. Test and scan

    composer require --dev drupal/core-dev phpstan/phpstan mglaman/phpstan-drupal drupal/coder
    composer audit
    vendor/bin/phpcs --standard=Drupal,DrupalPractice --extensions=php,module,inc,install,theme web/modules/custom web/themes/custom
    vendor/bin/phpstan analyse web/modules/custom --level=5
    vendor/bin/phpunit -c web/core web/modules/custom

    # Image vulnerability scan
    brew install trivy
    trivy image --severity HIGH,CRITICAL --exit-code 1 $ECR_REPO:app-dev

    # Every site bootstraps and config is in sync
    for s in $SITES; do
      docker compose exec app drush -l $s status --field=bootstrap
      docker compose exec app drush -l $s config:status
    done

**REVIEWED IMPLEMENTATION NOTE — Container build and local security**

Treat the Dockerfile and Compose snippets as templates, not copy/paste-ready files. Dockerfile instructions must be valid, including separate comments and correct COPY destinations. Build app and web targets independently; verify the frontend artifact path, PHP extensions, UID/GID, filesystem mounts, NGINX FastCGI routing, Drush bootstrap, and image scans. Bind mounts of web/sites can mask image-baked settings. Local demo credentials and TRUSTED_HOSTS=.\* must never be promoted to staging/production.

## Phases 12–14: AWS landing zone, EKS and supporting services

These are the CLI commands so every step is visible. For production, put the same resources in Terraform (`terraform-aws-modules/eks`, `/rds`, `/vpc`) and run `terraform plan` / `apply` through review, as your guide recommends.

### 12. Landing zone: cluster and VPC

eksctl creates the VPC (public subnets for the ALB, private subnets for nodes) and the cluster together.

    # Before provisioning: aws eks describe-cluster-versions --region "$AWS_REGION"; choose a supported version and pin it explicitly. Replace the placeholder below.
    # infra/cluster.yaml
    apiVersion: eksctl.io/v1alpha5
    kind: ClusterConfig
    metadata: { name: drupal-prod, region: us-east-1, version: "REPLACE_WITH_SUPPORTED_VERSION" }  # use the newest EKS standard-support version
    vpc:
      cidr: 10.20.0.0/16
      nat: { gateway: HighlyAvailable }
      clusterEndpoints: { publicAccess: true, privateAccess: true }
    iam: { withOIDC: true }
    addons:
      - { name: vpc-cni }
      - { name: coredns }
      - { name: kube-proxy }
      - { name: eks-pod-identity-agent }
      - { name: aws-efs-csi-driver }
      - { name: metrics-server }
    managedNodeGroups:
      - name: app
        instanceType: m6i.large
        minSize: 2
        desiredCapacity: 3
        maxSize: 6
        privateNetworking: true
        volumeEncrypted: true
    cloudWatch:
      clusterLogging: { enableTypes: ["api", "audit", "authenticator"] }
    aws budgets create-budget --account-id $AWS_ACCOUNT_ID \
      --budget '{"BudgetName":"drupal-eks","BudgetLimit":{"Amount":"2000","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'

    eksctl create cluster -f infra/cluster.yaml          # about 20 minutes
    aws eks update-kubeconfig --name $CLUSTER --region $AWS_REGION
    kubectl get nodes -o wide
    kubectl create namespace $NS

    # IDs used below
    export VPC_ID=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.vpcId --output text)
    export PRIVATE_SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=tag:kubernetes.io/role/internal-elb,Values=1 --query 'Subnets[].SubnetId' --output text)
    export NODE_SG=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)

### 13. Supporting services

**ECR**

    aws ecr create-repository --repository-name $ECR_REPO --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE --encryption-configuration encryptionType=KMS
    aws ecr put-lifecycle-policy --repository-name $ECR_REPO --lifecycle-policy-text \
      '{"rules":[{"rulePriority":1,"selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":50},"action":{"type":"expire"}}]}'

**RDS (MySQL 8.0, Multi-AZ; one instance, one database per site)**

    export DB_SG=$(aws ec2 create-security-group --group-name drupal-rds --description "Drupal RDS" --vpc-id $VPC_ID --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id $DB_SG --protocol tcp --port 3306 --source-group $NODE_SG
    aws rds create-db-subnet-group --db-subnet-group-name drupal-private \
      --db-subnet-group-description "Drupal private" --subnet-ids $PRIVATE_SUBNETS
    aws rds create-db-parameter-group --db-parameter-group-name drupal-mysql80 --db-parameter-group-family mysql8.0 --description Drupal
    aws rds modify-db-parameter-group --db-parameter-group-name drupal-mysql80 --parameters \
      "ParameterName=max_allowed_packet,ParameterValue=67108864,ApplyMethod=immediate" \
      "ParameterName=transaction_isolation,ParameterValue=READ-COMMITTED,ApplyMethod=immediate"

    aws rds create-db-instance --db-instance-identifier drupal-prod --engine mysql --engine-version 8.0 \
      --db-instance-class db.r6g.large --allocated-storage 100 --storage-type gp3 --storage-encrypted \
      --master-username admin --manage-master-user-password --multi-az \
      --db-subnet-group-name drupal-private --vpc-security-group-ids $DB_SG \
      --db-parameter-group-name drupal-mysql80 --backup-retention-period 14 \
      --deletion-protection --no-publicly-accessible --enable-performance-insights
    aws rds wait db-instance-available --db-instance-identifier drupal-prod
    export DB_HOST=$(aws rds describe-db-instances --db-instance-identifier drupal-prod --query 'DBInstances[0].Endpoint.Address' --output text)

**ElastiCache Redis**

    export REDIS_SG=$(aws ec2 create-security-group --group-name drupal-redis --description "Drupal Redis" --vpc-id $VPC_ID --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id $REDIS_SG --protocol tcp --port 6379 --source-group $NODE_SG
    aws elasticache create-cache-subnet-group --cache-subnet-group-name drupal-private \
      --cache-subnet-group-description "Drupal" --subnet-ids $PRIVATE_SUBNETS
    aws elasticache create-replication-group --replication-group-id drupal-redis \
      --replication-group-description "Drupal cache" --engine redis --cache-node-type cache.t4g.medium \
      --num-cache-clusters 2 --automatic-failover-enabled --cache-subnet-group-name drupal-private \
      --security-group-ids $REDIS_SG --at-rest-encryption-enabled
    export REDIS_HOST=$(aws elasticache describe-replication-groups --replication-group-id drupal-redis \
      --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)

**EFS for public and private files**

    export EFS_SG=$(aws ec2 create-security-group --group-name drupal-efs --description "Drupal EFS" --vpc-id $VPC_ID --query GroupId --output text)
    aws ec2 authorize-security-group-ingress --group-id $EFS_SG --protocol tcp --port 2049 --source-group $NODE_SG
    export EFS_ID=$(aws efs create-file-system --encrypted --performance-mode generalPurpose --throughput-mode elastic \
      --tags Key=Name,Value=drupal-files --query FileSystemId --output text)
    for sn in $PRIVATE_SUBNETS; do aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $sn --security-groups $EFS_SG; done
    aws efs put-backup-policy --file-system-id $EFS_ID --backup-policy Status=ENABLED

    cat <<EOF | kubectl apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata: { name: efs-drupal }
    provisioner: efs.csi.aws.com
    parameters: { provisioningMode: efs-ap, fileSystemId: $EFS_ID, directoryPerms: "775", uid: "82", gid: "82" }
    EOF

UID/GID 82 is `www-data` in Alpine images.

**AWS Load Balancer Controller**

    curl -o alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://alb-iam-policy.json
    eksctl create podidentityassociation --cluster $CLUSTER --namespace kube-system \
      --service-account-name aws-load-balancer-controller --create-service-account \
      --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy

    helm repo add eks https://aws.github.io/eks-charts && helm repo update
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
      --set clusterName=$CLUSTER --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller --set vpcId=$VPC_ID --set region=$AWS_REGION
    kubectl -n kube-system rollout status deploy/aws-load-balancer-controller

**TLS certificate (ACM)**

    export CERT_ARN=$(aws acm request-certificate --domain-name site-a.example.org \
      --subject-alternative-names site-b.example.org site-c.example.org \
      --validation-method DNS --query CertificateArn --output text)
    aws acm describe-certificate --certificate-arn $CERT_ARN --query 'Certificate.DomainValidationOptions[].ResourceRecord'
    # add those CNAMEs in Route 53, then:
    aws acm wait certificate-validated --certificate-arn $CERT_ARN

### 14. Databases, secrets and storage per site

**Secrets Manager:** one secret per site, plus shared values.

    # target_db comes from the same mapping file used for the Acquia backups (Phase 3)
    while IFS=, read -r s acquia_db target_db; do
      [ "$s" = site ] && continue
      aws secretsmanager create-secret --name drupal/prod/$s --secret-string "$(jq -n \
        --arg db "$target_db" --arg u "${target_db}_user" --arg p "$(openssl rand -base64 24)" \
        --arg salt "$(openssl rand -hex 32)" \
        '{db_name:$db, db_user:$u, db_password:$p, hash_salt:$salt}')"
    done < migration/inventory/site-databases.csv
    aws secretsmanager create-secret --name drupal/prod/shared --secret-string \
      "{\"db_host\":\"$DB_HOST\",\"redis_host\":\"$REDIS_HOST\"}"

**External Secrets Operator** syncs these into Kubernetes Secrets:

    helm repo add external-secrets https://charts.external-secrets.io
    helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace

    cat > eso-policy.json <<EOF
    {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
     "Resource":"arn:aws:secretsmanager:$AWS_REGION:$AWS_ACCOUNT_ID:secret:drupal/prod/*"}]}
    EOF
    aws iam create-policy --policy-name DrupalSecretsRead --policy-document file://eso-policy.json
    # The ESO controller reads Secrets Manager with its own identity
    eksctl create podidentityassociation --cluster $CLUSTER --namespace external-secrets \
      --service-account-name external-secrets \
      --permission-policy-arns arn:aws:iam::$AWS_ACCOUNT_ID:policy/DrupalSecretsRead
    kubectl -n external-secrets rollout restart deploy/external-secrets

**Create each site's database and user.** RDS is private, so run the client inside the cluster:

    MASTER_SECRET=$(aws rds describe-db-instances --db-instance-identifier drupal-prod --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
    MASTER_PW=$(aws secretsmanager get-secret-value --secret-id $MASTER_SECRET --query SecretString --output text | jq -r .password)

    SQL=""
    for s in $SITES; do
      SEC=$(aws secretsmanager get-secret-value --secret-id drupal/prod/$s --query SecretString --output text)
      DB=$(jq -r .db_name <<<"$SEC"); U=$(jq -r .db_user <<<"$SEC"); P=$(jq -r .db_password <<<"$SEC")
      SQL+="CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
      SQL+="CREATE USER IF NOT EXISTS '$U'@'%' IDENTIFIED BY '$P'; GRANT ALL ON \`$DB\`.* TO '$U'@'%';"
    done
    kubectl -n $NS run mysql-admin --rm -i --restart=Never --image=mysql:8.0 -- \
      mysql -h $DB_HOST -uadmin -p"$MASTER_PW" -e "$SQL"

| Site   | Database / user          | Secret               | Public files        | Private files        |
|--------|--------------------------|----------------------|---------------------|----------------------|
| site_a | `site_a` / `site_a_user` | `drupal/prod/site_a` | EFS `public/site_a` | EFS `private/site_a` |
| site_b | `site_b` / `site_b_user` | `drupal/prod/site_b` | EFS `public/site_b` | EFS `private/site_b` |

The table assumes each target_db equals the site name; use the values from site-databases.csv. MySQL user names are limited to 32 characters.

EFS is used for files because it behaves like the POSIX storage on Acquia. Move public files to S3 with `s3fs` later only after testing image styles, aggregation and private-file access.

## Phase 15: Kubernetes workload

All manifests go in `k8s/`. Hostname routing is done by Drupal's `sites.php`, so every host points at the same Service. The examples show two sites; repeat the per-site lines for each one.

    # Confirm served CRD versions first: kubectl get crd externalsecrets.external-secrets.io -o jsonpath="{.spec.versions[*].name}". Use v1 only if installed controller/CRDs serve it.
    # k8s/00-secrets.yaml
    apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    metadata: { name: aws-sm }
    spec:
      provider: { aws: { service: SecretsManager, region: us-east-1 } }
    ---
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata: { name: drupal-env, namespace: drupal }
    spec:
      refreshInterval: 1h
      secretStoreRef: { kind: ClusterSecretStore, name: aws-sm }
      target: { name: drupal-env }
      data:
        - { secretKey: DB_HOST,            remoteRef: { key: drupal/prod/shared, property: db_host } }
        - { secretKey: REDIS_HOST,         remoteRef: { key: drupal/prod/shared, property: redis_host } }
        - { secretKey: SITE_A_DB_NAME,     remoteRef: { key: drupal/prod/site_a, property: db_name } }
        - { secretKey: SITE_A_DB_USER,     remoteRef: { key: drupal/prod/site_a, property: db_user } }
        - { secretKey: SITE_A_DB_PASSWORD, remoteRef: { key: drupal/prod/site_a, property: db_password } }
        - { secretKey: SITE_A_HASH_SALT,   remoteRef: { key: drupal/prod/site_a, property: hash_salt } }
        - { secretKey: SITE_B_DB_NAME,     remoteRef: { key: drupal/prod/site_b, property: db_name } }
        - { secretKey: SITE_B_DB_USER,     remoteRef: { key: drupal/prod/site_b, property: db_user } }
        - { secretKey: SITE_B_DB_PASSWORD, remoteRef: { key: drupal/prod/site_b, property: db_password } }
        - { secretKey: SITE_B_HASH_SALT,   remoteRef: { key: drupal/prod/site_b, property: hash_salt } }
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata: { name: drupal-config, namespace: drupal }
    data:
      APP_ENV: prod
      SITE_A_TRUSTED_HOSTS: '^site-a\.example\.org$'
      SITE_B_TRUSTED_HOSTS: '^site-b\.example\.org$'
      TRUSTED_PROXY_IPS: 'REPLACE_WITH_ALB_PUBLIC_SUBNET_CIDRS'   # filled in once, Phase 15 apply step
    # k8s/10-storage.yaml
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata: { name: drupal-files, namespace: drupal }
    spec:
      accessModes: [ReadWriteMany]
      storageClassName: efs-drupal
      resources: { requests: { storage: 100Gi } }   # EFS ignores size, but the field is required
    # k8s/20-deployment.yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata: { name: drupal, namespace: drupal, labels: { app: drupal } }
    spec:
      # HPA controls replicas; omit spec.replicas after initial scale is established.
      strategy: { rollingUpdate: { maxUnavailable: 0, maxSurge: 1 } }
      selector: { matchLabels: { app: drupal } }
      template:
        metadata: { labels: { app: drupal } }
        spec:
          securityContext: { fsGroup: 82, runAsNonRoot: true }
          topologySpreadConstraints:
            - { maxSkew: 1, topologyKey: topology.kubernetes.io/zone, whenUnsatisfiable: ScheduleAnyway, labelSelector: { matchLabels: { app: drupal } } }
          containers:
            - name: app
              image: ACCOUNT.dkr.ecr.REGION.amazonaws.com/drupal-multisite:app-TAG
              envFrom: [ { secretRef: { name: drupal-env } }, { configMapRef: { name: drupal-config } } ]
              ports: [ { containerPort: 9000 } ]
              resources: { requests: { cpu: 250m, memory: 512Mi }, limits: { memory: 1Gi } }
              readinessProbe: { tcpSocket: { port: 9000 }, periodSeconds: 10 }
              livenessProbe:  { tcpSocket: { port: 9000 }, initialDelaySeconds: 20, periodSeconds: 20 }
              volumeMounts: &files
                - { name: files, mountPath: /var/www/html/web/sites/site_a/files, subPath: public/site_a }
                - { name: files, mountPath: /var/www/html/web/sites/site_b/files, subPath: public/site_b }
                - { name: files, mountPath: /mnt/private, subPath: private }
            - name: web
              image: ACCOUNT.dkr.ecr.REGION.amazonaws.com/drupal-multisite:web-TAG
              ports: [ { containerPort: 8080 } ]
              securityContext: { runAsUser: 101 }
              resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 256Mi } }
              readinessProbe: { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 10 }
              startupProbe:   { httpGet: { path: /healthz, port: 8080 }, failureThreshold: 30, periodSeconds: 2 }
              volumeMounts: *files
          volumes:
            - { name: files, persistentVolumeClaim: { claimName: drupal-files } }

The `web` image is built on `nginx-unprivileged`, so it runs as UID 101 on port 8080 without root.

    # k8s/30-network.yaml
    apiVersion: v1
    kind: Service
    metadata: { name: drupal, namespace: drupal }
    spec:
      selector: { app: drupal }
      ports: [ { port: 80, targetPort: 8080 } ]
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: drupal
      namespace: drupal
      annotations:
        alb.ingress.kubernetes.io/scheme: internet-facing
        alb.ingress.kubernetes.io/target-type: ip
        alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
        alb.ingress.kubernetes.io/ssl-redirect: "443"
        alb.ingress.kubernetes.io/certificate-arn: CERT_ARN
        alb.ingress.kubernetes.io/healthcheck-path: /healthz
        alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=120
        # alb.ingress.kubernetes.io/wafv2-acl-arn: WAF_ARN
    spec:
      ingressClassName: alb
      rules:
        - host: site-a.example.org
          http: { paths: [ { path: /, pathType: Prefix, backend: { service: { name: drupal, port: { number: 80 } } } } ] }
        - host: site-b.example.org
          http: { paths: [ { path: /, pathType: Prefix, backend: { service: { name: drupal, port: { number: 80 } } } } ] }
    # k8s/40-scaling.yaml
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    metadata: { name: drupal, namespace: drupal }
    spec:
      scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: drupal }
      minReplicas: 3
      maxReplicas: 12
      metrics: [ { type: Resource, resource: { name: cpu, target: { type: Utilization, averageUtilization: 65 } } } ]
    ---
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata: { name: drupal, namespace: drupal }
    spec:
      minAvailable: 2
      selector: { matchLabels: { app: drupal } }
    # Generate per-site CronJobs from a single reviewed site inventory (e.g. Helm values.yaml). The two-site command below is illustrative only. Forbid applies per CronJob; Drupal cron lock handles per-site contention.
    # k8s/50-cron.yaml  (replaces Acquia scheduled jobs)
    apiVersion: batch/v1
    kind: CronJob
    metadata: { name: drupal-cron, namespace: drupal }
    spec:
      schedule: "*/15 * * * *"
      concurrencyPolicy: Forbid
      jobTemplate:
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              securityContext: { fsGroup: 82 }
              containers:
                - name: cron
                  image: ACCOUNT.dkr.ecr.REGION.amazonaws.com/drupal-multisite:app-TAG
                  envFrom: [ { secretRef: { name: drupal-env } }, { configMapRef: { name: drupal-config } } ]
                  command: ["bash", "-c", "for s in site_a site_b; do drush -l $s cron || echo \"cron failed: $s\"; done"]
                  volumeMounts:
                    - { name: files, mountPath: /var/www/html/web/sites/site_a/files, subPath: public/site_a }
                    - { name: files, mountPath: /var/www/html/web/sites/site_b/files, subPath: public/site_b }
                    - { name: files, mountPath: /mnt/private, subPath: private }
              volumes: [ { name: files, persistentVolumeClaim: { claimName: drupal-files } } ]
    # k8s/jobs/deploy-job.yaml  (template; CI fills TAG and SITE; replaces BLT drupal:update and Cloud Hooks)
    apiVersion: batch/v1
    kind: Job
    metadata: { name: JOBNAME, namespace: drupal }
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          securityContext: { fsGroup: 82 }
          containers:
            - name: deploy
              image: ACCOUNT.dkr.ecr.REGION.amazonaws.com/drupal-multisite:app-TAG
              envFrom: [ { secretRef: { name: drupal-env } }, { configMapRef: { name: drupal-config } } ]
              command: ["drush", "-l", "SITE", "deploy", "-y"]
              volumeMounts:
                - { name: files, mountPath: /var/www/html/web/sites/SITE/files, subPath: public/SITE }
                - { name: files, mountPath: /mnt/private, subPath: private }
          volumes: [ { name: files, persistentVolumeClaim: { claimName: drupal-files } } ]

**Apply and verify**

    # Replace this sed-based illustrative deployment with Helm values and immutable image digests or Kustomize overlays; do not use string substitutions for production deployments.
    # Fill placeholders for a manual apply (CI does this in Phase 16)
    export TAG=$GIT_SHA
    # One-time: write the ALB public subnet CIDRs into the ConfigMap and commit it
    ALB_SUBNET_CIDRS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
      Name=tag:kubernetes.io/role/elb,Values=1 --query 'Subnets[].CidrBlock' --output text | tr '\t' ',')
    echo "$ALB_SUBNET_CIDRS"
    sed -i "s#REPLACE_WITH_ALB_PUBLIC_SUBNET_CIDRS#$ALB_SUBNET_CIDRS#" k8s/00-secrets.yaml

    for f in k8s/*.yaml; do
      sed -e "s#ACCOUNT.dkr.ecr.REGION.amazonaws.com#$ECR#g" -e "s#app-TAG#app-$TAG#g" -e "s#web-TAG#web-$TAG#g" \
          -e "s#CERT_ARN#$CERT_ARN#g" $f | kubectl apply -f -
    done

    kubectl -n $NS get externalsecret drupal-env          # STATUS SecretSynced
    kubectl -n $NS get pvc drupal-files                   # Bound
    # First apply only: start at the HPA minimum so the PDB (minAvailable: 2) does not block drains
    kubectl -n $NS scale deployment/drupal --replicas=3
    kubectl -n $NS rollout status deployment/drupal
    kubectl -n $NS get pods -o wide
    # Proxy check: the client IP in logs should be yours, not an ALB address
    kubectl -n $NS exec deploy/drupal -c app -- drush -l site_a watchdog:show --count=5
    kubectl -n $NS get ingress drupal                     # ADDRESS = ALB DNS name
    export ALB=$(kubectl -n $NS get ingress drupal -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

    # Create per-site file directories on EFS once
    kubectl -n $NS exec deploy/drupal -c app -- bash -c 'for s in site_a site_b; do mkdir -p /mnt/private/$s; done'
    kubectl -n $NS exec deploy/drupal -c app -- drush -l site_a status

    # Optional: enforce NetworkPolicy with the VPC CNI
    aws eks update-addon --cluster-name $CLUSTER --addon-name vpc-cni \
      --configuration-values '{"enableNetworkPolicy":"true"}'

## Phase 16: CI/CD pipeline

Pull requests run checks only. A merge to `main` builds both images once, deploys them to staging, then waits for approval before production. GitHub reaches AWS through OIDC, so no long-lived keys are stored.

### One-time AWS setup for GitHub

    aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com

    cat > gha-trust.json <<EOF
    {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
     "Principal":{"Federated":"arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"},
     "Action":"sts:AssumeRoleWithWebIdentity",
     "Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
       "StringLike":{"token.actions.githubusercontent.com:sub":"repo:myorg/drupal-platform:*"}}}]}
    EOF
    aws iam create-role --role-name gha-drupal-deploy --assume-role-policy-document file://gha-trust.json
    aws iam attach-role-policy --role-name gha-drupal-deploy --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
    aws iam put-role-policy --role-name gha-drupal-deploy --policy-name eks-rds --policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["eks:DescribeCluster","rds:CreateDBSnapshot","rds:DescribeDBSnapshots"],"Resource":"*"}]}'

    # Let the role deploy into the drupal namespace only
    aws eks create-access-entry --cluster-name $CLUSTER --principal-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/gha-drupal-deploy
    aws eks associate-access-policy --cluster-name $CLUSTER \
      --principal-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/gha-drupal-deploy \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
      --access-scope type=namespace,namespaces=drupal,drupal-staging

    # Store the role ARN and settings in GitHub
    gh secret set AWS_DEPLOY_ROLE --body arn:aws:iam::$AWS_ACCOUNT_ID:role/gha-drupal-deploy
    gh variable set AWS_REGION --body $AWS_REGION
    gh variable set ECR --body $ECR
    gh variable set CERT_ARN --body $CERT_ARN
    gh api -X PUT repos/myorg/drupal-platform/environments/production \
      -F 'reviewers[][type]=Team' -F 'reviewers[][id]=<team-id>'   # approval gate

For staging, apply the Phase 15 manifests to a `drupal-staging` namespace with its own secrets (`drupal/staging/*`), databases and hostnames.

### Workflow

    # .github/workflows/ci-cd.yml
    name: ci-cd
    on:
      pull_request:
      push: { branches: [main] }
    permissions: { id-token: write, contents: read }
    concurrency: { group: deploy-${{ github.ref }}, cancel-in-progress: false }

    jobs:
      test:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: shivammathur/setup-php@v2
            with: { php-version: '8.3', tools: composer:v2 }
          - run: composer validate --strict && composer install --prefer-dist --no-progress
          - run: composer audit
          - run: vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom web/themes/custom
          - run: vendor/bin/phpstan analyse web/modules/custom --level=5
          - run: vendor/bin/phpunit -c web/core web/modules/custom

      build:
        needs: test
        if: github.event_name == 'push'
        runs-on: ubuntu-latest
        outputs: { tag: ${{ steps.t.outputs.tag }} }
        steps:
          - uses: actions/checkout@v4
          - id: t
            run: echo "tag=$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT
          - uses: aws-actions/configure-aws-credentials@v4
            with: { role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE }}, aws-region: ${{ vars.AWS_REGION }} }
          - uses: aws-actions/amazon-ecr-login@v2
          - uses: docker/setup-buildx-action@v3
          - uses: docker/build-push-action@v6
            with: { target: app, push: true, tags: "${{ vars.ECR }}/drupal-multisite:app-${{ steps.t.outputs.tag }}", cache-from: type=gha, cache-to: "type=gha,mode=max" }
          - uses: docker/build-push-action@v6
            with: { target: web, push: true, tags: "${{ vars.ECR }}/drupal-multisite:web-${{ steps.t.outputs.tag }}", cache-from: type=gha }
          - uses: aquasecurity/trivy-action@0.28.0
            with: { image-ref: "${{ vars.ECR }}/drupal-multisite:app-${{ steps.t.outputs.tag }}", severity: "HIGH,CRITICAL", exit-code: "1", ignore-unfixed: true }

      deploy-staging:
        needs: build
        runs-on: ubuntu-latest
        environment: staging
        steps:
          - uses: actions/checkout@v4
          - uses: aws-actions/configure-aws-credentials@v4
            with: { role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE }}, aws-region: ${{ vars.AWS_REGION }} }
          - run: aws eks update-kubeconfig --name drupal-prod
          - run: ./scripts/deploy.sh drupal-staging ${{ needs.build.outputs.tag }}
            env: { ECR: "${{ vars.ECR }}", CERT_ARN: "${{ vars.CERT_ARN }}", BASE_DOMAIN: stg.example.org }

      deploy-production:
        needs: [build, deploy-staging]
        runs-on: ubuntu-latest
        environment: production          # waits for reviewer approval
        steps:
          - uses: actions/checkout@v4
          - uses: aws-actions/configure-aws-credentials@v4
            with: { role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE }}, aws-region: ${{ vars.AWS_REGION }} }
          - run: aws eks update-kubeconfig --name drupal-prod
          - run: ./scripts/deploy.sh drupal ${{ needs.build.outputs.tag }}
            env: { ECR: "${{ vars.ECR }}", CERT_ARN: "${{ vars.CERT_ARN }}", BASE_DOMAIN: example.org }

### Deploy script

    # REFERENCE ONLY: replace sed render() and hardcoded SITES with Helm templates driven by values.yaml; deploy images by immutable digest. Preserve sequential per-site Jobs and stop on failure.
    #!/usr/bin/env bash
    # scripts/deploy.sh <namespace> <tag>
    set -euo pipefail
    NS=$1; TAG=$2
    SITES="site_a site_b"
    render() { sed -e "s#ACCOUNT.dkr.ecr.REGION.amazonaws.com#$ECR#g" -e "s#app-TAG#app-$TAG#g" -e "s#web-TAG#web-$TAG#g" \
                   -e "s#CERT_ARN#$CERT_ARN#g" -e "s#namespace: drupal\$#namespace: $NS#" \
                   -e "s#host: \(.*\)\.example\.org#host: \1.$BASE_DOMAIN#" "$@"; }

    # 1. Database snapshot (the only real rollback for schema changes)
    if [ "$NS" = drupal ]; then
      aws rds create-db-snapshot --db-instance-identifier drupal-prod --db-snapshot-identifier predeploy-$TAG-$(date +%s)
    fi

    # 2. Roll out the new code
    for f in k8s/*.yaml; do render "$f" | kubectl apply -f -; done
    kubectl -n $NS rollout status deployment/drupal --timeout=10m

    # 3. Run drush deploy (updatedb, config:import, cache:rebuild, deploy hooks) per site, one at a time
    for s in $SITES; do
      JOB=drupal-deploy-${s//_/-}-$TAG
      render k8s/jobs/deploy-job.yaml | sed -e "s#JOBNAME#$JOB#" -e "s#SITE#$s#g" | kubectl apply -f -
      if ! kubectl -n $NS wait --for=condition=complete job/$JOB --timeout=15m; then
        kubectl -n $NS logs job/$JOB; echo "Deploy failed on $s"; exit 1
      fi
      kubectl -n $NS logs job/$JOB | tail -20
    done

    # 4. Smoke tests
    for h in site-a site-b; do
      code=$(curl -s -o /dev/null -w "%{http_code}" https://$h.$BASE_DOMAIN/)
      echo "$h.$BASE_DOMAIN -> $code"; [ "$code" = 200 ] || exit 1
    done
    chmod +x scripts/deploy.sh
    git add .github scripts k8s Dockerfile docker compose.yaml .dockerignore
    git commit -m "Container build, EKS manifests and CI/CD"
    git push -u origin migration/remove-acquia-blt
    gh pr create --fill

Job names must be valid DNS labels, so the script swaps underscores for hyphens (`site_a` becomes `site-a`). The `render` function also rewrites Ingress hosts to `$BASE_DOMAIN`; give the staging namespace its own `drupal-config` ConfigMap with staging trusted-host patterns.

**REVIEWED IMPLEMENTATION NOTE — Cloud infrastructure gates**

Provision EKS, RDS, networking, EFS, IAM, Secrets Manager and ingress through reviewed infrastructure-as-code for production. Validate EKS version support, cluster access, least-privilege pod identity, security-group sources, encrypted storage, image digest pinning, TLS, network policies, autoscaling and backup restoration. Do not infer a working installation from successful resource creation alone.

## Phases 17–18: Migrate data, rehearse, validate

### 17. Migrate data into staging (repeat for each rehearsal)

A toolbox pod with the app image, the EFS volume and DB credentials does all imports from inside the VPC.

    # Toolbox pod
    kubectl -n $NS run toolbox --image=$ECR/$ECR_REPO:app-$TAG --restart=Never \
      --overrides='{"spec":{"securityContext":{"fsGroup":82},"containers":[{"name":"toolbox","image":"'$ECR/$ECR_REPO:app-$TAG'",
      "command":["sleep","86400"],"envFrom":[{"secretRef":{"name":"drupal-env"}},{"configMapRef":{"name":"drupal-config"}}],
      "volumeMounts":[{"name":"files","mountPath":"/mnt/efs"}]}],
      "volumes":[{"name":"files","persistentVolumeClaim":{"claimName":"drupal-files"}}]}}'
    kubectl -n $NS wait --for=condition=Ready pod/toolbox

    # Fresh export from Acquia
    D=backups/$(date +%F-%H%M); mkdir -p $D
    for s in $SITES; do
      vendor/bin/drush @$ACQUIA_APP.$ACQUIA_ENV -l $s sql:dump --gzip --structure-tables-key=common > $D/$s.sql.gz
      vendor/bin/drush rsync @$ACQUIA_APP.$ACQUIA_ENV:%files/ $D/$s-files/ -l $s -y
      vendor/bin/drush rsync @$ACQUIA_APP.$ACQUIA_ENV:%private/ $D/$s-private/ -l $s -y
    done

    # Import into RDS and EFS
    for s in $SITES; do
      S=$(echo $s | tr a-z A-Z)
      kubectl -n $NS cp $D/$s.sql.gz toolbox:/tmp/$s.sql.gz
      kubectl -n $NS exec toolbox -- bash -c "drush -l $s sql:drop -y && gunzip -c /tmp/$s.sql.gz | drush -l $s sql:cli && rm /tmp/$s.sql.gz"
      tar -C $D/$s-files -czf - . | kubectl -n $NS exec -i toolbox -- bash -c "mkdir -p /mnt/efs/public/$s && tar -C /mnt/efs/public/$s -xzf -"
      tar -C $D/$s-private -czf - . | kubectl -n $NS exec -i toolbox -- bash -c "mkdir -p /mnt/efs/private/$s && tar -C /mnt/efs/private/$s -xzf -"
    done

    # Staging only: sanitize personal data
    for s in $SITES; do kubectl -n $NS exec toolbox -- drush -l $s sql:sanitize -y; done

    # Apply the new code's updates and config
    for s in $SITES; do
      kubectl -n $NS exec toolbox -- drush -l $s deploy -y
      kubectl -n $NS exec toolbox -- drush -l $s config:status          # expect no differences
      kubectl -n $NS exec toolbox -- drush -l $s core:requirements --severity=2
      kubectl -n $NS exec toolbox -- drush -l $s search-api:reset-tracker && \
        kubectl -n $NS exec toolbox -- drush -l $s search-api:index
      kubectl -n $NS exec toolbox -- drush -l $s cron
    done
    kubectl -n $NS exec toolbox -- drush -l site_a watchdog:show --severity=Error --count=20

For large file trees, `aws datasync` or an `rsync` from an EC2 instance that mounts EFS is faster than `kubectl exec` with tar. Time each rehearsal: that time sets your cutover freeze window.

Test against staging without DNS changes:

    ALB_IP=$(dig +short $ALB | head -1)
    curl -sI --resolve site-a.example.org:443:$ALB_IP https://site-a.example.org/ | head -5

### 18. Validate performance, reliability and compliance

    # Load test: same script against Acquia (baseline) and EKS
    brew install k6
    cat > loadtest.js <<'EOF'
    import http from 'k6/http'; import { check, sleep } from 'k6';
    export const options = { stages: [{duration:'2m',target:50},{duration:'5m',target:200},{duration:'2m',target:0}],
      thresholds: { http_req_duration: ['p(95)<800'], http_req_failed: ['rate<0.01'] } };
    const paths = ['/', '/news', '/search?keys=test', '/contact'];
    export default function () {
      const r = http.get(`${__ENV.BASE}${paths[Math.floor(Math.random()*paths.length)]}`);
      check(r, { 'status 200': (x) => x.status === 200 }); sleep(1);
    }
    EOF
    k6 run -e BASE=https://site-a.example.org loadtest.js            # baseline on Acquia
    k6 run -e BASE=https://site-a.stg.example.org loadtest.js        # EKS staging

    # Watch scaling and resources while the test runs
    kubectl -n $NS get hpa drupal -w
    kubectl -n $NS top pods
    aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
      --dimensions Name=DBInstanceIdentifier,Value=drupal-prod --start-time $(date -u -d '-1 hour' +%FT%TZ) \
      --end-time $(date -u +%FT%TZ) --period 60 --statistics Maximum

    # Resilience: kill a pod and drain a node mid-test
    kubectl -n $NS delete $(kubectl -n $NS get pod -l app=drupal -o name | head -1) --wait=false
    kubectl drain $(kubectl get nodes -o name | head -1) --ignore-daemonsets --delete-emptydir-data
    kubectl uncordon $(kubectl get nodes -o name | head -1)

    # Accessibility and TLS
    npx pa11y-ci --sitemap https://site-a.stg.example.org/sitemap.xml
    docker run --rm drwetter/testssl.sh https://site-a.stg.example.org

    # Restore test: prove RDS snapshot restore and time it (RTO evidence)
    SNAP=$(aws rds describe-db-snapshots --db-instance-identifier drupal-prod --query 'DBSnapshots[-1].DBSnapshotIdentifier' --output text)
    time aws rds restore-db-instance-from-db-snapshot --db-instance-identifier drupal-restore-test \
      --db-snapshot-identifier $SNAP --db-subnet-group-name drupal-private --vpc-security-group-ids $DB_SG
    aws rds wait db-instance-available --db-instance-identifier drupal-restore-test
    aws rds delete-db-instance --db-instance-identifier drupal-restore-test --skip-final-snapshot

Record the results against `migration/ACCEPTANCE.md` from Phase 4 before scheduling cutover.

**REVIEWED IMPLEMENTATION NOTE — Release and rollback gates**

Use a single per-release Drupal deployment Job and per-site cron with locking. Verify all site hostnames, file writes, integrations, accessibility, load benchmarks, logs and alerts. Establish content freeze or dual-write reconciliation before cutover. DNS or kubectl rollback alone cannot reverse Drupal database schema changes or recover writes; restore a compatible code/database/files/config checkpoint and reconcile post-cutover changes.

## Phases 19–20: Cutover, rollback, decommission

### 19. Prepare (2–7 days before)

    export ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name example.org --query 'HostedZones[0].Id' --output text)
    export ALB_ZONE=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB'].CanonicalHostedZoneId" --output text)

    # Lower TTL to 60s on every site record (do this at least one old-TTL period ahead)
    for h in site-a site-b; do
      aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{"Changes":[{"Action":"UPSERT",
       "ResourceRecordSet":{"Name":"'$h'.example.org","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"<current-acquia-target>"}]}}]}'
    done
    dig +noall +answer site-a.example.org

    # Run a full rehearsal of Phase 17 against production namespace and time it
    # Confirm the code rollback path works (code only; DB uses snapshots)
    kubectl -n $NS rollout history deployment/drupal

If your DNS is not in Route 53, make the same TTL and record changes at your current provider.

### 20. Cutover runbook

    # T-0: freeze content on Acquia
    for s in $SITES; do acli remote:drush $ACQUIA_APP.$ACQUIA_ENV -- -l $s state:set system.maintenance_mode 1 --input-format=integer; done
    for s in $SITES; do acli remote:drush $ACQUIA_APP.$ACQUIA_ENV -- -l $s cache:rebuild; done

    # Final sync: rerun the Phase 17 export + import block (without sql:sanitize!)

    # Verify each site on EKS before DNS moves
    for s in $SITES; do
      kubectl -n $NS exec toolbox -- drush -l $s deploy -y
      kubectl -n $NS exec toolbox -- drush -l $s state:set system.maintenance_mode 0 --input-format=integer
      kubectl -n $NS exec toolbox -- drush -l $s cache:rebuild
    done
    ALB_IP=$(dig +short $ALB | head -1)
    for h in site-a site-b; do curl -s -o /dev/null -w "$h %{http_code}\n" --resolve $h.example.org:443:$ALB_IP https://$h.example.org/; done

    # Switch DNS (alias to the ALB, or to CloudFront if you front it)
    for h in site-a site-b; do
      aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch '{"Changes":[
       {"Action":"DELETE","ResourceRecordSet":{"Name":"'$h'.example.org","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"<current-acquia-target>"}]}},
       {"Action":"CREATE","ResourceRecordSet":{"Name":"'$h'.example.org","Type":"A",
         "AliasTarget":{"HostedZoneId":"'$ALB_ZONE'","DNSName":"'$ALB'","EvaluateTargetHealth":true}}}]}'
    done

    # Monitor
    watch -n 10 'for h in site-a site-b; do curl -s -o /dev/null -w "$h %{http_code} %{time_total}s\n" https://$h.example.org/; done'
    kubectl -n $NS logs deploy/drupal -c web --since=10m | awk "\$9 ~ /^5/" | tail
    kubectl -n $NS exec toolbox -- drush -l site_a watchdog:show --severity=Error --count=20

    # Clean up
    kubectl -n $NS delete pod toolbox

### Rollback

| Problem                                     | Action                                                        | Commands                                                                                                                     |
|---------------------------------------------|---------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| Bad release after cutover, no schema change | Roll back code                                                | `kubectl -n drupal rollout undo deployment/drupal`                                                                           |
| Bad release with schema or config change    | Restore the pre-deploy snapshot and redeploy the previous tag | `aws rds restore-db-instance-from-db-snapshot ...`, update the `DB_HOST` secret, `./scripts/deploy.sh drupal <previous-tag>` |
| Cutover fails                               | Point DNS back to Acquia, take Acquia out of maintenance mode | Route 53 UPSERT to the old CNAME, `acli remote:drush ... state:set system.maintenance_mode 0`                                |

Once content is created on EKS, a DNS rollback loses it unless you sync it back. Agree a cutoff (for example 24 hours) after which you fix forward only.

### Decommission (after exit criteria and retention are met)

    # Final archive of Acquia data, then remove Acquia hooks and remote
    for s in $SITES; do vendor/bin/drush @$ACQUIA_APP.$ACQUIA_ENV -l $s sql:dump --gzip > archive/$s-acquia-final.sql.gz; done
    aws s3 cp archive/ s3://myorg-drupal-archive/acquia-final/ --recursive --storage-class GLACIER
    git rm -r hooks/ factory-hooks/ 2>/dev/null; git remote remove acquia
    git commit -m "Remove Acquia hooks after migration"
    # Raise DNS TTL back to 3600 and close the Acquia subscription

## After cutover: Drupal 11 and daily commands

### Drupal 11 upgrade

With BLT gone, nothing blocks Drupal 11. Acquia lists Drupal 10 end of life as 9 December 2026, so schedule this right after stabilization.

    git checkout -b upgrade/drupal-11
    composer require --dev drupal/upgrade_status
    forsites pm:enable upgrade_status -y
    forsites upgrade_status:analyze --all

    composer why-not drupal/core-recommended:^11      # shows modules that block the upgrade
    composer require drupal/core-recommended:^11 drupal/core-composer-scaffold:^11 \
      drupal/core-project-message:^11 --update-with-all-dependencies --no-update
    composer require --dev drupal/core-dev:^11 --no-update
    composer update -W

    docker compose up -d --build && docker compose exec app bash -c 'for s in site_a site_b; do drush -l $s deploy -y; done'
    forsites config:export -y
    git commit -am "Upgrade to Drupal 11" && gh pr create --fill   # CI deploys to staging, then production

### Cheat sheet

| Task                            | Command                                                                                                                                                                                                         |
|---------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Start local stack               | `docker compose up -d`                                                                                                                                                                                          |
| Drush on one site locally       | `docker compose exec app drush -l site_a <cmd>`                                                                                                                                                                 |
| Drush on one site in production | `kubectl -n drupal exec deploy/drupal -c app -- drush -l site_a <cmd>`                                                                                                                                          |
| Pull prod DB to local           | `kubectl -n drupal exec deploy/drupal -c app -- drush -l site_a sql:dump --gzip > a.sql.gz`, then `gunzip -c a.sql.gz | docker compose exec -T app drush -l site_a sql:cli`                                     |
| Deploy                          | Merge to `main`, then approve the production environment in GitHub                                                                                                                                              |
| Watch a rollout                 | `kubectl -n drupal rollout status deployment/drupal`                                                                                                                                                            |
| Code rollback                   | `kubectl -n drupal rollout undo deployment/drupal`                                                                                                                                                              |
| Logs                            | `kubectl -n drupal logs deploy/drupal -c app --since=15m`                                                                                                                                                       |
| Run cron now                    | `kubectl -n drupal create job cron-now --from=cronjob/drupal-cron`                                                                                                                                              |
| Add a site                      | Add `sites.php` entry, `sites/<new>/settings.php`, `config/<new>/sync`, Secrets Manager secret, ExternalSecret keys, Ingress host, volume mounts, ACM SAN; then `drush -l <new> site:install --existing-config` |

**Architect Review Addendum — Required Validation Before Production Use**

This addendum documents review findings and acceptance gates. It supplements, rather than certifies, the 20-step example commands above.

**1. Settings and reverse proxy**

Retain site-specific settings, trusted host rules, config sync paths, hash salts and private-file paths. Do not dynamically trust every REMOTE_ADDR as a proxy. Restrict direct origin traffic and use only known proxy ranges or addresses; validate forwarded headers with actual ALB/CloudFront topology.

**2. Composer and Acquia BLT**

Inspect composer.json and composer.lock, BLT recipes, hooks, settings includes, patches, CI scripts and Acquia-only modules. Replace each function before removing the BLT package. Run composer validate, composer audit, per-site Drush bootstrap, tests, and a lockfile review after the minimal necessary dependency change.

**3. Database and storage**

Use complete database dumps and a documented site-to-database mapping. Test public/private files, image styles, upload writes, ownership and EFS performance. Use per-site credentials where feasible. Encrypt backups and rehearse point-in-time restore and site-level rollback.

**4. Containers and local development**

Separate build-time and runtime assets, avoid copying secrets into images, pin supported base images, and validate Dockerfile syntax with actual builds. Avoid host mounts that replace built settings unexpectedly. Use unique local-only credentials and restricted host patterns.

**5. EKS and CI/CD**

Validate Kubernetes YAML with schema tools and a real non-production deployment. Pin image digests, require approval for production, use short-lived GitHub OIDC credentials, configure least-privilege AWS roles, and verify EFS CSI/ALB controllers and Secrets Manager integration.

**6. Interfaces and data synchronization**

Add an inventory of REST/JSON:API, GraphQL, SSO, external search, webhooks, scheduled imports, outbound notifications and third-party endpoints. For each integration record authentication, rate limits, mapping, retries, idempotency, ownership, and cutover testing.

**7. Architecture decisions and performance**

Write ADRs for EKS versus ECS, EFS versus S3, multisite tenancy boundaries, Redis cache, and database isolation. Record baseline and target p50/p95/p99 latency, throughput, error rate, CPU, memory, DB load and autoscaling, and label unmeasured targets as targets.

**8. Compliance and executive communication**

Map controls to actual client requirements (for example Section 508/WCAG and applicable agency security baselines). Add an executive one-page summary, RACI, change approvals, risk register, migration waves, go/no-go criteria, and post-cutover owner sign-off.

**9. Evidence checklist**

Attach sanitized GitHub repository, successful build/test logs, redacted infrastructure plan, screenshots of multisite routing, backup-restore test, load test report, vulnerability scan, deployment Job results, rollback rehearsal, and approved release checklist. Mark incomplete evidence as pending.

Portfolio description: Proposed Drupal Multisite Acquia BLT-to-AWS EKS Reference Architecture and Migration Runbook. Do not describe it as a completed production migration without deployment evidence.
