#!/bin/sh
# LedgerSMB's command-line administration (ledgersmb-admin), with its libraries
export PERL5LIB=/usr/lib/ledgersmb/perl5/lib/perl5 LSMB_CONFIG_FILE=/etc/ledgersmb/ledgersmb.yaml
cd /usr/share/ledgersmb || exit 1
exec perl -I lib -I old/lib bin/ledgersmb-admin "$@"
