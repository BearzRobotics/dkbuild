#!/bin/sh
# Nextcloud's console (occ), run as the PHP user
if [ "$(id -u)" = 0 ]; then
    exec su -s /bin/sh _php -c 'exec /usr/bin/php -d memory_limit=512M /usr/share/nextcloud/occ "$@"' -- occ "$@"
fi
exec /usr/bin/php -d memory_limit=512M /usr/share/nextcloud/occ "$@"
