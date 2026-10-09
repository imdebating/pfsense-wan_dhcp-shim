#!/bin/sh
# bell-admz-boot.sh -- restore the enter-hook link after boot or a
# pfSense upgrade.  Installed as /usr/local/etc/rc.d/bell-admz.sh,
# which pfSense runs with "start" at boot and on package reloads, so
# this must be idempotent.  It never touches interface state.

CONF=/conf/bell-admz-shield/config
HOOK_SRC=/conf/bell-admz-shield/dhclient-enter-hooks
HOOK_LINK=/etc/dhclient-enter-hooks
DHS=/usr/local/sbin/pfSense-dhclient-script

case "${1:-start}" in
	start|faststart|restart) ;;
	*) exit 0 ;;
esac

[ -r "$CONF" ] || exit 0
[ -r "$HOOK_SRC" ] || exit 0
. "$CONF"
[ "${BELL_ADMZ_ENABLED:-0}" = "1" ] || exit 0

# Upgrade guard: only restore the link if the stock script still
# supports enter hooks WITH abort-on-exit_status semantics.  If an
# upgrade removed or changed the seam, keep stock DHCP behaviour.
if /usr/bin/grep -q '/etc/dhclient-enter-hooks' "$DHS" 2>/dev/null && \
   /usr/bin/grep -A6 'dhclient-enter-hooks' "$DHS" 2>/dev/null | /usr/bin/grep -q 'exit_status'; then
	if [ "$(/usr/bin/readlink "$HOOK_LINK" 2>/dev/null)" != "$HOOK_SRC" ]; then
		/bin/ln -sf "$HOOK_SRC" "$HOOK_LINK" 2>/dev/null
		/usr/bin/logger -t bell-admz "restored enter hook for ${BELL_ADMZ_IFACE} (mode ${BELL_ADMZ_MODE})"
	fi
else
	/usr/bin/logger -t bell-admz "$DHS no longer supports the enter hook; keeping stock DHCP behaviour"
fi
exit 0
