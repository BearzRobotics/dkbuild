#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

# A live system's / is an overlay (a RAM layer over a read-only image). It is
# already writable, and the kernel refuses to remount an overlay
# ("No changes allowed in reconfigure"), so there is nothing to do.
if [ "$(findmnt -n -o FSTYPE -M /)" = overlay ]; then
  exit 0
fi

exec mount -n -o remount,rw /
