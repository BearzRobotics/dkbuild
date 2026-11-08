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

  # Users, groups, directories and files packages declare (sysusers.d,
  # tmpfiles.d): /run is new at every boot. sd-tools is in base.
  if [ -x /usr/bin/sd-sysusers ]; then /usr/bin/sd-sysusers || :; fi
  if [ -x /usr/bin/sd-tmpfiles ]; then /usr/bin/sd-tmpfiles --create --remove --boot || :; fi
  #mkdir -m og-w /var/run/dbus
  
  # A machine id without D-Bus (the CLI system has none): the kernel's random
  # UUID without dashes is the same format dbus-uuidgen writes.
  if [ ! -s /etc/machine-id ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
    chmod 0444 /etc/machine-id
  fi


  # Configure random number generator
  if [ -e /var/lib/random-seed ]; then
    cat /var/lib/random-seed > /dev/urandom
  fi
  
  # Configure network
  ip link set lo up        # the kernel adds 127.0.0.1/8 and ::1 itself

  # You can put other static configuration here:
  #/sbin/ifconfig eth0 192.168.1.38 netmask 255.255.255.0 broadcast 192.168.1.255

  if [ -s /etc/hostname ]; then cat /etc/hostname > /proc/sys/kernel/hostname; fi

  # /usr/sbin/alsactl restore

else

  # The system is being shut down
  
  # echo "Saving random number seed..."
  POOLSIZE="$(cat /proc/sys/kernel/random/poolsize)"
  mkdir -p /var/lib
  dd if=/dev/urandom of=/var/lib/random-seed bs="$POOLSIZE" count=1 2> /dev/null

fi;
