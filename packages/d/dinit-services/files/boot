# Waits for the optional serial console (ttyS0) so machines without a serial port still boot.
# This is the primary service, automatically started when the system comes up.

type = internal

# Each of these services starts a login prompt:
depends-ms: tty1
depends-ms: tty2
depends-ms: tty3
depends-ms: tty4
depends-ms: tty5
depends-ms: tty6

# Serial console; waits-for so a missing port does not block boot:
waits-for: ttyS0

# the boot.d directory contents determine other dependencies:
waits-for.d: boot.d
