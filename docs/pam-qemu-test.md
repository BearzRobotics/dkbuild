# PAM: build and QEMU test plan (2026-11-15)

**Result, 2026-11-15: passed.** shadow r6, sudo r4 and openssh r5 were built and the base
ISO made from them boots in QEMU (UEFI and BIOS) and passes `tests/qemu-pam.sh`: console
login as `live` (empty password), `sudo` for a wheel user, `useradd` + `chpasswd`, `su`
with the right and a wrong password, `sudo` refused for a user outside wheel, ssh to
localhost with the right and a wrong password, `su` and `sudo` setuid. Not tested: polkit,
cronie, cups, samba (built with PAM in their recipes, not built yet), graphical logins
(greetd, SDDM), `passwd` as a normal user. Findings: `useradd` warned that group 100 does
not exist (default.useradd now names 999, shadow r7); the base image has no `grep`
(unrelated to PAM; to look at). Run it again with:

    tests/qemu-pam.sh out/base/base.iso uefi

PAM is adopted system-wide (memory/docs: shadow, sudo, openssh, polkit, cronie, cups,
samba switched; commit d05cb1a). Nothing had been built or booted with it. This is the
plan to prove login works before anyone relies on it. A mistake in a PAM stack locks
users out, so none of these packages should reach a real install before this passes.

## 1. Build the packages

The world run is stopped for this (it shares `repo/` and its index). Then:

    DKBUILD_FAST_WORK=$HOME/.cache/dkbuild-work ./zig-out/bin/dkbuild pkg -P 3 --no-check --color=always shadow sudo openssh > work/pam-build.log 2>&1

(shadow r6, sudo r4, openssh r5, plus whatever in their build roots is stale.) Read
`work/pam-build.log` with `less -R`. Not needed for the login test: polkit r5, cronie r2,
cups r2, samba r7 (build them after, or in the next world run).

## 2. Make the image

    ./zig-out/bin/dkbuild image images/base.toml

`images/base.toml` is the base live system: base, base-net, linux, live-initramfs,
dkinstaller, firmware; user `live` (wheel, empty password, autologin on tty1).

## 3. Boot it

    tests/qemu-iso.sh out/base/base.iso uefi        # then also: bios

The script passes when the serial console reaches the login prompt and the live user
logs in. The serial log is `work/qemu-base-uefi.log`. For an interactive session:
`qemu-system-x86_64 -m 2G -accel kvm -cpu host -cdrom out/base/base.iso -nographic`
(UEFI needs OVMF as in the script).

## 4. What to check by hand (the script does only the first)

1. Console login as `live` (no password: the empty password must still work through
   system-auth's `nullok`).
2. A password login: `passwd live` to set one, log out, log in with it; a wrong
   password is refused.
3. `su -` to root from `live`, and `su live` from root (root needs no password).
4. `sudo -i`, `sudo id`: asks for the password, works for `wheel`, refused for a user not in
   `wheel`.
5. `useradd test; passwd test; chsh test` as root; `chage -l test`.
6. sshd: `dinitctl start sshd` (or its service), `ssh live@localhost` from inside the VM
   (and from the host with `-nic user,hostfwd=tcp::2222-:22`): password login works,
   wrong password refused, `UsePAM yes` in `/etc/ssh/sshd_config`.
7. No "PAM" errors in the log (`/var/log` or the serial log): `grep -i pam`; and
   `ls /usr/lib/pam.d` shows login, su, su-l, passwd, sudo, sudo-i, sshd and the
   system-* stacks.

## 5. If something fails

The stacks are in `packages/s/shadow/files/pam.d/`, `packages/s/sudo/files/`,
`packages/o/openssh/files/sshd.pam` (and polkit-1.pam, crond.pam, cups.pam); the shared
ones (system-auth, system-login, system-remote-login, system-services) in
`packages/l/linux-pam-base/files/`. Fix the recipe, bump the release, rebuild the one
package, rebuild the image. A broken stack on the booted VM can be repaired from the
serial console only if root has a shell: keep a root session open while editing
`/usr/lib/pam.d`.

## 6. After it passes

- Restart the world run (all fixes queued in the recipes are picked up):

      DKBUILD_FAST_WORK=$HOME/.cache/dkbuild-work ./zig-out/bin/dkbuild world -P 3 --no-check --keep-going --color=always > work/world.log 2>&1

- Still to do for PAM: the other PAM-capable daemons (dovecot, exim, forgejo/gitea),
  `pam_selinux` in system-login when SELinux lands, dkconsole/greetd/SDDM check.
- Lomiri's lock screen and greeter need PAM and LightDM (wip/queue/lomiri/NOTES.md).
