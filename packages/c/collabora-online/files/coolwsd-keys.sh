#!/bin/sh
# This machine's own keys for coolwsd, made once (the coolwsd-keys service): the WOPI proof key, and a
# self-signed TLS certificate until a real one replaces it (/etc/coolwsd/{cert,key,ca-chain}.pem), or
# ssl.enable=false behind a proxy.
set -e
cd /etc/coolwsd
if [ ! -e proof_key ]; then
    su -s /bin/sh cool -c "coolconfig generate-proof-key" > /dev/null 2>&1 || echo "coolwsd-keys: no proof key made" >&2
fi
if [ ! -e cert.pem ]; then
    umask 077
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=$(cat /etc/hostname 2>/dev/null || echo localhost)" \
        -keyout key.pem -out cert.pem > /dev/null 2>&1
    cp cert.pem ca-chain.cert.pem
    chown cool:cool key.pem cert.pem ca-chain.cert.pem
    chmod 644 cert.pem ca-chain.cert.pem
fi
