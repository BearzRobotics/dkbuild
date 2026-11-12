#!/bin/sh
# Znuny's console (as the znuny user): znuny Maint::Config::Rebuild, ...
export PERL5LIB=/usr/lib/znuny/perl5/lib/perl5 HOME=/opt/znuny
if [ "$(id -un)" = znuny ]; then exec /usr/bin/perl /opt/znuny/bin/znuny.Console.pl "$@"; fi
exec su -s /bin/sh znuny -c 'PERL5LIB=/usr/lib/znuny/perl5/lib/perl5 /usr/bin/perl /opt/znuny/bin/znuny.Console.pl "$@"' -- znuny "$@"
