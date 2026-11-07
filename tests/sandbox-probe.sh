#!/bin/sh
# Checks, from the inside, that this process is in the build sandbox (SPEC.md 7.1).
# Prints a line per violation and exits 1 if there were any.
fail=0
bad() { echo "VIOLATION: $*"; fail=1; }

# Network: a new network namespace has only the loopback interface.
if [ -r /proc/net/dev ] && grep -E '^ *[A-Za-z0-9._-]+:' /proc/net/dev | grep -v -E '^ *lo:' >/dev/null; then
    bad "network interface other than lo is visible"
fi
# And an actual connection attempt must fail (needs a compiler; skipped without one).
if command -v clang >/dev/null 2>&1; then
    cat > /tmp/conn.c <<'C'
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(53)};
    inet_pton(AF_INET, "1.1.1.1", &a.sin_addr);
    return connect(s, (struct sockaddr *)&a, sizeof a) == 0 ? 1 : 0;
}
C
    clang /tmp/conn.c -o /tmp/conn 2>/dev/null && { /tmp/conn || bad "connected to 1.1.1.1:53"; }
fi
# The host user's home directory is not visible. (The image may have /home of
# its own; the test substitutes the host's real path for the placeholder. Run
# directly on the host, the placeholder stays and $HOME is used, which exists.)
HOST_HOME="@HOSTHOME@"
case "$HOST_HOME" in @*) HOST_HOME=$HOME ;; esac
[ ! -e "$HOST_HOME" ] || bad "the host home directory $HOST_HOME is visible"
# Its processes are not visible: only the few in this PID namespace.
n=$(ls /proc | grep -c '^[0-9][0-9]*$')
[ "$n" -le 12 ] || bad "$n processes visible in /proc"
# Root inside, with a clean environment.
[ "$(id -u)" = 0 ] || bad "not uid 0 inside"
[ "$HOME" = /root ] || bad "HOME is $HOME"
[ -z "${SSH_AUTH_SOCK:-}${DISPLAY:-}${WSL_DISTRO_NAME:-}" ] || bad "host environment leaked"
exit $fail
