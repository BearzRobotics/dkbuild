#!/bin/sh
# Sets the system time from the hardware clock (the hwclock service).
#
# hwclock first waits, through /dev/rtc0, for the clock to tick. Where the clock's interrupt never arrives that times
# out after about ten seconds ("select() to /dev/rtc0 to wait for clock tick timed out"), seen on a real BIOS machine
# and under QEMU. --directisa reads the clock through its I/O ports instead, which needs no interrupt (PC hardware
# only: elsewhere the second try fails too, and the service with it).
PATH=/usr/bin:/usr/sbin:/bin:/sbin

hwclock --hctosys && exit 0
echo "hwclock: could not read the clock through /dev/rtc0; reading it directly (--directisa)"
exec hwclock --hctosys --directisa
