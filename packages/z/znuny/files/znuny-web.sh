#!/bin/sh
export PERL5LIB=/usr/lib/znuny/perl5/lib/perl5 HOME=/opt/znuny
exec /usr/lib/znuny/perl5/bin/starman --listen 127.0.0.1:5000 --workers 4 /opt/znuny/bin/cgi-bin/app.psgi
