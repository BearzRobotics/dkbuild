#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

set -e

if [ "$1" != "stop" ]; then

  echo "Mounting auxillary filesystems...."
  # --onlyonce: what is already mounted from the same source at the same place is left alone, without an error
  mount --onlyonce -avt noproc,nonfs

fi;
