# lfs-12.3-dinit-service-files

## dkrescue branch

Adapts these service files for dkrescue, a musl + LLVM rescue distro running
dinit 0.20. Changes from `main`:

- **Host keys at first start.** New `sshd-keys` service runs `ssh-keygen -A`,
  which creates any missing host keys and does nothing once they exist.
  `sshd` depends on it. Keys are never baked into the image, since every copy
  of the ISO would otherwise share them.
- **sshd on demand.** `boot.d/sshd` is removed, so sshd does not run at boot
  (the disk is often booted on networks I don't control). Start it with
  `dinitctl start sshd`. `dhcpcd` is still started at boot.
- **Serial console.** `ttyS0` now runs `agetty -L 115200 ttyS0 vt100` with a
  normal login (no autologin) for QEMU `-nographic` and headless machines.
  `boot` uses `waits-for` so a machine with no serial port still boots.
