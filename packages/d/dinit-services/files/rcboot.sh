#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
umask 0077

set -e

if [ "$1" != "stop" ]; then
  
  # cleanup
  # (delete /tmp etc)
  rm -rf /tmp/* /tmp/.[!.]* /tmp/..?*
  
  # empty utmp, create needed directories
  : > /var/run/utmp
  #mkdir -m og-w /var/run/dbus
  
  dbus-uuidgen --ensure=/etc/machine-id


  # Configure random number generator
  if [ -e /var/state/random-seed ]; then
    cat /var/state/random-seed > /dev/urandom;
  fi
  
  # Configure network
  ip link set lo up        # the kernel adds 127.0.0.1/8 and ::1 itself

  # You can put other static configuration here:
  #/sbin/ifconfig eth0 192.168.1.38 netmask 255.255.255.0 broadcast 192.168.1.255

  [ -s /etc/hostname ] && cat /etc/hostname > /proc/sys/kernel/hostname

  # /usr/sbin/alsactl restore

else

  # The system is being shut down
  
  # echo "Saving random number seed..."
  POOLSIZE="$(cat /proc/sys/kernel/random/poolsize)"
  dd if=/dev/urandom of=/var/state/random-seed bs="$POOLSIZE" count=1 2> /dev/null

fi;
