# SELinux for FenrirOS: plan and status (2026-11-15)

Requested for Red Hat family users (AlmaLinux): Red Hat's policy, targeted, permissive by default;
the installer labels files and touches /.autorelabel (docs/requests.md, memory).

## Written in wip/queue/packages (not built)

SELinux userspace 3.11 (github.com/SELinuxProject/selinux), after Alpine's recipes and patches:
audit (libaudit, auditd), libsepol, libselinux (no Python/Ruby bindings), checkpolicy, libsemanage,
policycoreutils (setfiles, restorecon, load_policy, semodule, sestatus, setsebool, newrole, run_init,
secon; PAM-using, which the system-wide PAM adoption allows), secilc, mcstrans, selinux-python
(its semanage and sepolicy need the Python bindings below).

## Still to do, in this order

1. **Python bindings** of libselinux and libsemanage (swig is in the tree): then semanage, sepolicy,
   audit2allow work. setools (Python, Cython) for sepolicy and the analysis tools.
2. **The policy**: Red Hat's `selinux-policy` (fedora-selinux/selinux-policy, a fork of the upstream
   reference policy with Fedora's modules, built with `make NAME=targeted TYPE=standard DISTRO=redhat`;
   container-selinux for Incus/podman) or the upstream refpolicy (refpolicy 2.20260922 releases a
   tarball). It needs checkpolicy, semodule-utils (not written), m4, python and a lot of build time;
   `selinux-policy-targeted` is the package users know. Its file contexts name the paths of
   Fedora's layout (/usr/sbin, /lib64 ...): FenrirOS's layout differs (no /lib64, merged /usr), so
   the file contexts need adapting (fcontext equivalences with `semanage fcontext -a -e`, or a patch).
3. **PAM**: linux-pam built with `-Dselinux=enabled` (pam_selinux) and the login/su/sshd/sudo stacks
   gain `pam_selinux` lines (close/open session), system-login included.
4. **SELinux-aware builds** (--with-selinux / ls -Z): coreutils (ls -Z, cp -a, install -Z), util-linux, tar,
   shadow, openssh (sshd labels), sudo, findutils, cronie (--with-selinux), systemd-less init hooks in dinit.
5. **Kernel**: `linux` and `linux-lts` with CONFIG_SECURITY_SELINUX, SECURITY_SELINUX_BOOTPARAM,
   AUDIT, FS xattr labels (the root filesystem types), NETLABEL; boot parameter `selinux=1 enforcing=0`
   (permissive) in the image's boot configuration.
6. **Init and installer**: dinit services (auditd; loading the policy is the kernel's/`load_policy` at early boot),
   /etc/selinux/config with SELINUX=permissive, and the installer step in /stuff/git/dkinstaller
   (setfiles on the target, /.autorelabel as the fallback).
7. **snapd** for SELinux systems: devmode/classic only (docs/requests.md).

## Update 2026-11-15 (policy and bindings written)

Added to the queue: semodule-utils, restorecond, python-selinux and python-semanage (the bindings, built from the
libselinux and libsemanage sources with swig), setools (Cython, networkx), and
**selinux-policy-targeted** (Red Hat/Fedora's policy: fedora-selinux/selinux-policy, pinned rawhide commit
5df1131 = 41.34, + container-selinux 2.251.0, modular, MCS, `make base modules install ...` as the project's INSTALL
describes; `scripts/post-install` runs semodule to build the store; `/etc/selinux/config` is `SELINUX=permissive`,
`SELINUXTYPE=targeted`), with a first local module `fenriros` (files/fenriros.{te,fc,if}: musl's loader, dinit
and /etc/dinit.d labels). 15 SELinux recipes in all. UNVERIFIED parts are named in the policy recipe's header.

Next in the SELinux list: PAM with `pam_selinux` (linux-pam `-Dselinux=enabled`, stacks), coreutils/util-linux/
tar/shadow/openssh/sudo/cronie built with SELinux, the kernel options, dinit hooks and the installer step.
Those change packages that are in the main tree: they wait for the policy to build and for the QEMU boot test.

## Update 2026-11-15: the integration script

`wip/queue/selinux/integrate.sh` (POSIX sh, dash- and shellcheck-clean, tested on a copy of the recipes) does the edits in the
main tree that turn SELinux on, once the SELinux packages have built and a QEMU boot has been tried: linux-pam
`-Dselinux=enabled`, `pam_selinux.so close/open` in linux-pam-base's system-login, shadow, openssh, cronie, sudo and
NetworkManager built with SELinux, libselinux-devel added to coreutils, findutils, tar and util-linux (their configure scripts use it
when found); each touched package gets a release bump. NOT run yet: it would rebuild the base of the tree and a mistake in a
PAM stack locks users out (run tests/qemu-pam.sh after it). Found while writing it: the kernel configs (`linux`, `linux-lts`) already
have SELinux built in (SECURITY_SELINUX=y, bootparam, develop mode, LSM list with selinux, default SELinux), so step 5 of the
plan above is done; the live squashfs has no xattr support (CONFIG_SQUASHFS_XATTR is not set), so the live ISO cannot carry labels
(an installed system on ext4, btrfs or xfs can). Remaining: dinit's early-boot policy load (a service running `load_policy -i`),
the installer step, a `selinux=1 enforcing=0` boot entry, and the policy's FenrirOS module.
