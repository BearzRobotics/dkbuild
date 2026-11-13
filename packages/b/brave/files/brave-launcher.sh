#!/bin/sh
#
# FenrirOS: packages/c/chromium's launcher (Chimera's, adapted from Alpine)
# for Brave: /etc/brave/*.conf, BRAVE_FLAGS/BRAVE_USER_FLAGS, Brave's
# desktop file name (brave-browser.desktop, as upstream's wrapper sets it, so
# windows get its icon) and the brave binary.

for f in /etc/brave/*.conf; do
  [ -f "$f" ] && . "$f"
done

# the defaults to use if nothing else is defined
if [ -z "${BRAVE_FLAGS+x}" ]; then
  BRAVE_FLAGS="--ozone-platform-hint=auto"
fi

# Append BRAVE_USER_FLAGS (from env) on top of system
# default BRAVE_FLAGS (from /etc/brave/brave.conf).
BRAVE_FLAGS="$BRAVE_FLAGS ${BRAVE_USER_FLAGS:+"$BRAVE_USER_FLAGS"}"

# Let the wrapped binary know that it has been run through the wrapper
export CHROME_WRAPPER="$(readlink -f "$0")"

PROGDIR=${CHROME_WRAPPER%/*}

case ":$PATH:" in
*:$PROGDIR:*)
  # $PATH already contains $PROGDIR
  ;;
*)
  # Append $PROGDIR to $PATH
  export PATH="$PATH:$PROGDIR"
  ;;
esac

if [ $(id -u) -eq 0 ] && [ $(stat -c %u -L ${XDG_CONFIG_HOME:-${HOME}}) -eq 0 ]; then
  # Running as root with HOME owned by root.
  # Pass --user-data-dir to work around upstream failsafe.
  BRAVE_FLAGS="--user-data-dir=${XDG_CONFIG_HOME:-"$HOME"/.config}/BraveSoftware/Brave-Browser $BRAVE_FLAGS"
fi

# Set the .desktop file name
export CHROME_DESKTOP="brave-browser.desktop"
export CHROME_VERSION_EXTRA="FenrirOS"

exec "$PROGDIR/brave" ${BRAVE_FLAGS} "$@"
