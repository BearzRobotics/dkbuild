#!/bin/sh
# LedgerSMB under Starman on localhost:5762 (nginx proxies to it)
export PERL5LIB=/usr/lib/ledgersmb/perl5/lib/perl5 LSMB_CONFIG_FILE=/etc/ledgersmb/ledgersmb.yaml
cd /usr/share/ledgersmb || exit 1
exec /usr/lib/ledgersmb/perl5/bin/starman --preload-app --listen 127.0.0.1:5762 \
    -I lib -I old/lib bin/ledgersmb-server.psgi
