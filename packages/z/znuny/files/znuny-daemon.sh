#!/bin/sh
export PERL5LIB=/usr/lib/znuny/perl5/lib/perl5 HOME=/opt/znuny
exec /usr/bin/perl /opt/znuny/bin/znuny.Daemon.pl start --foreground
