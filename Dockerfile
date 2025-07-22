ARG PHP_VERSION=8.3
ARG XDEBUG_VERSION=3.3.1

# Versions
FROM dunglas/frankenphp:1-php${PHP_VERSION}-alpine AS frankenphp_upstream

# Base FrankenPHP image
FROM frankenphp_upstream AS frankenphp_base

WORKDIR /app

# persistent / runtime deps
# hadolint ignore=DL3018
RUN apk add --no-cache \
        acl \
        file \
        gettext \
        git \
        postgresql-dev \
        supervisor \
        dcron \
    ;

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
    icu-dev \
    libzip-dev \
    zlib-dev \
    libpq-dev \
    libpng-dev \
    ; \
    \
    docker-php-ext-configure zip; \
    docker-php-ext-install -j$(nproc) \
    intl \
    pdo_pgsql \
    zip \
    ; \
    docker-php-ext-enable \
    opcache \
    ; \
    \
    runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .app-phpexts-rundeps $runDeps; \
    \
    apk del .build-deps

RUN set -eux; \
    install-php-extensions \
        @composer \
        apcu \
    ;

RUN set -eux; \
    apk add --no-cache --virtual .build-deps autoconf linux-headers gcc make g++;

# Install PGSQL extension
# RUN docker-php-ext-install pdo_pgsql

# COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
# https://getcomposer.org/doc/03-cli.md#composer-allow-superuser
ENV COMPOSER_ALLOW_SUPERUSER=1

###> recipes ###
###< recipes ###

COPY --link frankenphp/conf.d/app.ini $PHP_INI_DIR/conf.d/
COPY --link --chmod=755 frankenphp/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY --link frankenphp/caddy/Caddyfile /etc/caddy/Caddyfile

# Copy supervisor configuration file
COPY --link frankenphp/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN mkdir -p /var/log/supervisord
RUN chown -R root:root /var/log/supervisord

# Add cron jobs for Symfony commands
COPY --link frankenphp/crontab /etc/cron.d/app-cron
# Set appropriate permissions and apply cron jobs
RUN chmod 0644 /etc/cron.d/app-cron
RUN crontab /etc/cron.d/app-cron
RUN touch /var/log/cron.log

ENTRYPOINT ["docker-entrypoint"]

HEALTHCHECK --start-period=60s CMD curl -f http://localhost:2019/metrics || exit 1

# Start supervisord with a specified configuration file path
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

###
# DEV FrankenPHP image
FROM frankenphp_base AS frankenphp_dev

ENV APP_ENV=dev

VOLUME /app/var/

RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

RUN set -eux; \
    install-php-extensions \
    xdebug \
    ;

COPY --link frankenphp/conf.d/app.dev.ini $PHP_INI_DIR/conf.d/

# CMD [ "frankenphp", "run", "--config", "/etc/caddy/Caddyfile", "--watch" ]
# Start supervisord with a specified configuration file path
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
### End dev

###
# PROD FrankenPHP image
FROM frankenphp_base AS frankenphp_prod

ENV APP_ENV=prod
ENV FRANKENPHP_CONFIG="import worker.Caddyfile"

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY --link frankenphp/conf.d/app.prod.ini $PHP_INI_DIR/conf.d/
COPY --link frankenphp/caddy/worker.Caddyfile /etc/caddy/worker.Caddyfile

# prevent the reinstallation of vendors at every changes in the source code
COPY --link composer.* symfony.* ./
RUN set -eux; \
    composer install --prefer-dist --no-dev --no-scripts --no-progress --no-interaction; \
    composer clear-cache

# copy sources
COPY --link . ./
RUN rm -Rf frankenphp/

RUN set -eux; \
    mkdir -p var/cache var/log public/uploads/profile_images; \
    composer dump-autoload --classmap-authoritative --no-dev; \
    composer dump-env prod; \
    composer run-script --no-dev post-install-cmd; \
    chmod +x bin/console; sync;

EXPOSE 80 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
