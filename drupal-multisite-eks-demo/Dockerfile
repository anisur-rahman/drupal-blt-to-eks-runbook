FROM composer:2 AS composer-bin

FROM php:8.3-apache
RUN apt-get update && apt-get install -y --no-install-recommends \
    git unzip libicu-dev libzip-dev libpng-dev libjpeg-dev libfreetype6-dev libonig-dev default-mysql-client \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip opcache \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer-bin /usr/bin/composer /usr/local/bin/composer
# Production PHP defaults: errors are logged, never printed into pages.
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
ENV APACHE_DOCUMENT_ROOT=/var/www/html/web
RUN sed -ri 's!/var/www/html!/var/www/html/web!g' /etc/apache2/sites-available/*.conf /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf
WORKDIR /var/www/html
COPY composer.json ./
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
COPY web/sites/sites.php web/sites/sites.php
COPY web/sites/default/settings.php web/sites/default/settings.php
COPY web/sites/site_a/settings.php web/sites/site_a/settings.php
COPY web/sites/site_b/settings.php web/sites/site_b/settings.php
COPY scripts/ scripts/
COPY config/ config/
RUN mkdir -p web/sites/site_a/files web/sites/site_b/files \
    && chown -R www-data:www-data web/sites/site_a/files web/sites/site_b/files
EXPOSE 80
