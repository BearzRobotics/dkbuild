#!/bin/sh
# pve-guests (dinit): what Debian's pve-guests.service runs
case $1 in
    start)
        /usr/share/pve-manager/helpers/pve-startall-delay || true
        exec /usr/bin/pvesh --nooutput create /nodes/localhost/startall ;;
    stop)
        /usr/bin/vzdump -stop || true
        exec /usr/bin/pvesh --nooutput create /nodes/localhost/stopall ;;
esac
