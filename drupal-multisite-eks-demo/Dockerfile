# syntax=docker/dockerfile:1
# Runbook Phase 9: one Dockerfile, two images that run side by side in each pod.
#   app  PHP-FPM 8.3 with the Drupal code (listens on 9000, runs as www-data UID 82)
#   web  unprivileged nginx with the same web root (listens on 8080, runs as UID 101)
# Build: docker build --target app -t drupal-multisite:app-dev .
#        docker build --target web -t drupal-multisite:web-dev .

# --- PHP runtime shared by the build stage and the app image -------------------------
FROM php:8.3-fpm-alpine AS php-base
RUN apk add --no-cache bash mariadb-client icu-libs libpng libjpeg-turbo freetype libzip \
 && apk add --no-cache --virtual .build $PHPIZE_DEPS icu-dev libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql gd opcache intl zip \
 && pecl install apcu redis \
 && docker-php-ext-enable apcu redis \
 && apk del .build \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY --chmod=644 docker/php/drupal.ini "$PHP_INI_DIR/conf.d/zz-drupal.ini"
# PHP-FPM clears the environment by default (clear_env = yes), which would hide every
# DB_*, SITE_*_* and TRUSTED_PROXY_IPS variable from settings.shared.php.
COPY --chmod=644 docker/php/zz-env.conf /usr/local/etc/php-fpm.d/zz-env.conf
WORKDIR /var/www/html

# --- Build: Composer dependencies, scaffold files and site settings ------------------
FROM php-base AS vendor
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-progress --no-interaction
COPY web/sites/sites.php web/sites/settings.shared.php web/sites/
COPY web/sites/default/settings.php web/sites/default/
COPY web/sites/site_a/settings.php web/sites/site_a/
COPY web/sites/site_b/settings.php web/sites/site_b/
COPY config/ config/
COPY scripts/ scripts/
# A checkout on exFAT/NTFS or a Windows host arrives as 0700/0777. Code stays root-owned
# and read-only to the web server; only the files directories are writable.
RUN composer install --no-dev --optimize-autoloader --no-progress --no-interaction \
 && find web/sites config scripts -type d -exec chmod 755 {} + \
 && find web/sites config scripts -type f -exec chmod 644 {} + \
 && chmod 755 scripts/*.sh \
 && mkdir -p web/sites/site_a/files web/sites/site_b/files

# --- app: PHP-FPM ---------------------------------------------------------------------
FROM php-base AS app
COPY --from=vendor /var/www/html /var/www/html
RUN mkdir -p /mnt/private/site_a /mnt/private/site_b \
 && chown -R 82:82 web/sites/site_a/files web/sites/site_b/files /mnt/private
ENV PATH="/var/www/html/vendor/bin:${PATH}"
USER 82:82
EXPOSE 9000

# --- web: nginx ------------------------------------------------------------------------
FROM nginxinc/nginx-unprivileged:1.27-alpine AS web
COPY --chmod=644 docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=vendor /var/www/html/web /var/www/html/web
EXPOSE 8080
