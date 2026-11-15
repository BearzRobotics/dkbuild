# 0003: snapd is not packaged

Status: decided 2026-11-15 (the user, after the survey in `docs/requests.md`). Revisit only if
the facts below change.

## Problem

snapd (Canonical's snap package manager) was requested ("add snap to the repo"). It is a Go
daemon with a C helper (snap-confine) and a Python-free client; the project ships ready-made vendored
Go dependencies, so building it offline would not be the hard part.

## Why it was dropped

snapd's design assumes systemd. As far as the survey of its design and of other distributions shows
(it was not tried here):

1. **Mounts.** Every installed snap is a squashfs image mounted through a *systemd mount unit*
   (`snap-<name>-<revision>.mount`); snapd drives it with `systemctl`.
2. **Services, timers, sockets.** A snap's daemons, its scheduled tasks and the refresh logic are systemd
   service, timer and socket units that snapd writes and controls. snapd itself starts through
   `snapd.socket` and `snapd.service`.
3. **Sandboxing.** snap-confine sets up namespaces and cgroups and expects systemd's cgroup layout and
   its transient scopes (`systemd-run`); strict confinement also wants AppArmor (not packaged here;
   a SELinux system is limited to devmode or classic confinement, see `docs/requests.md`).
4. **No supported non-systemd path.** Alpine, Void and Artix do not support snapd; the community attempts
   are partial. FenrirOS runs dinit and elogind.

A snapd package here would build and install, and then fail to install any snap. A compatibility layer
that imitates systemd's unit and mount handling for dinit would be a large project of its own, with a
security-sensitive part (sandboxing) that would have to be right.

## Decision

- **No snapd package.** It is removed from the queue and from the roadmap.
- **Use Flatpak** (in the tree, with the Flathub remote as the default) for sandboxed desktop applications,
  and native packages, AppImages or a venv/podman/Incus container where those fit. Most software that
  is published as a snap is also available that way.
- If a specific snap-only program is needed, say which: the answer may be to package that program
  natively.

## What would change this

systemd (or a supported non-systemd mode of snapd) in the tree: neither is planned.
