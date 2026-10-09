#!/bin/sh
# uninstall-bell-admz.sh -- removes only files managed by the
# bell-admz shim.  Stock pfSense DHCP behaviour resumes at the next
# DHCP event with no reboot and no manual reload required.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run as root on pfSense"

if [ -e /etc/dhclient-enter-hooks ] || [ -L /etc/dhclient-enter-hooks ]; then
	LINK=$(/usr/bin/readlink /etc/dhclient-enter-hooks 2>/dev/null || true)
	case "$LINK" in
		"")
			die "/etc/dhclient-enter-hooks is a regular file not managed here; inspect and remove manually"
			;;
		/conf/bell-admz-shield/*)
			/bin/rm -f /etc/dhclient-enter-hooks && say "removed /etc/dhclient-enter-hooks"
			;;
		*)
			die "/etc/dhclient-enter-hooks points at '$LINK', not managed here; remove manually"
			;;
	esac
fi

/bin/rm -f /usr/local/etc/rc.d/bell-admz.sh && say "removed /usr/local/etc/rc.d/bell-admz.sh"
/bin/rm -rf /var/run/bell-admz

if [ -d /conf/bell-admz-shield ]; then
	TS=$(date +%Y%m%d-%H%M%S)
	/bin/mv /conf/bell-admz-shield "/conf/bell-admz-shield.removed-$TS"
	say "persistent copy preserved at /conf/bell-admz-shield.removed-$TS"
fi

say "Stock pfSense DHCP behaviour resumes at the next DHCP event (no reboot needed)."
say "To force one full normal cycle now: Status > Interfaces > Renew, with console access."
say "Reference backups of pfSense originals are under /root/bell-admz-backup-* if you kept them."
exit 0
