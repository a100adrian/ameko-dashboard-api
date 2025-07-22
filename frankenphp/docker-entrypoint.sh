#!/bin/sh
set -e

echo "Running docker-entrypoint.sh"
echo "Current APP_ENV: $APP_ENV"
echo "Current SITE_BASE_URL: $SITE_BASE_URL"

# Print the value of $1
echo "The first argument is: $1"

if [ "$1" = 'frankenphp' ] || [ "$1" = 'php' ] || [ "$1" = 'messenger' ] || [ "$1" = 'bin/console' ] || [ "$1" = '/usr/bin/supervisord' ]; then
	# Install the project the first time PHP is started
	# After the installation, the following block can be deleted
	if [ ! -f composer.json ]; then
		rm -Rf tmp/
		composer create-project "symfony/skeleton $SYMFONY_VERSION" tmp --stability="$STABILITY" --prefer-dist --no-progress --no-interaction --no-install

		cd tmp
		cp -Rp . ..
		cd -
		rm -Rf tmp/

		composer require "php:>=$PHP_VERSION" runtime/frankenphp-symfony
		composer config --json extra.symfony.docker 'true'

		if grep -q ^DATABASE_URL= .env; then
			echo "To finish the installation please press Ctrl+C to stop Docker Compose and run: docker compose up --build -d --wait"
			sleep infinity
		fi
	fi

	# if [ -z "$(ls -A 'vendor/' 2>/dev/null)" ]; then
	echo "Running composer install..."
	composer install --prefer-dist --no-progress --no-interaction
	# fi

	# Disabled for now
	# echo "Waiting for db to be ready..."
	# until bin/console doctrine:query:sql "SELECT 1" > /dev/null 2>&1; do
	# 	sleep 1
	# done

	echo "Running migrations..."
	bin/console doctrine:migrations:migrate --no-interaction
	
	# if ls -A migrations/*.php > /dev/null 2>&1; then
		# echo "Resetting database..."
		# composer ws:db:reset
	# fi

	if [ "$APP_ENV" != 'prod' ] && [ "$LOAD_FIXTURES" = 'true' ] && [ -d src/DataFixtures ] && ls -A src/DataFixtures/*.php > /dev/null 2>&1; then
		echo "Loading fixtures..."
		# Reset DB
		# composer ws:db:reset
		# bin/console doctrine:fixtures:load --no-interaction
		if [ "$APP_ENV" = 'dev' ]; then
		  echo "Test database setup in dev environment..."
		  APP_ENV='test' composer ws:db:reset
    	fi
	fi

	setfacl -R -m u:www-data:rwX -m u:"$(whoami)":rwX var
	setfacl -dR -m u:www-data:rwX -m u:"$(whoami)":rwX var
fi

# Dump the Caddyfile content
echo "Dumping Caddyfile content:"
cat /etc/caddy/Caddyfile

exec docker-php-entrypoint "$@"
