#!/bin/sh
#──────────────────────────────────────────────────────────────────────────#
#                                                                          #
#       888888    888888              88     888888                        #
#         88      88                  88     88   oo                       #
#         88      88                  88     88                            #
#         88      8888 .d8b.   .d8b.  88     8888 88 8888b.  .d8b.         #
#         88      88  d8P Y8b d8P Y8b 88     88   88 88  8b d8P Y8b        #
#         88      88  8888888 8888888 88     88   88 88  88 8888888        #
#         88      88  Y8b.    Y8b.    88     88   88 88  88 Y8b.           #
#       888888    88   ºY888P  ºY888P 88     88   88 88  88  ºY888P        #
#                                                                          #
#                                          (c) 2015-2026 I Feel Fine, Inc. #
#──────────────────────────────────────────────────────────────────────────#
# Licensed under the Apache License, Version 2.0 (the "License");          #
# you may not use this file except in compliance with the License.         #
# You may obtain a copy of the License at                                  #
#                                                                          #
#     http://www.apache.org/licenses/LICENSE-2.0                           #
#                                                                          #
# Unless required by applicable law or agreed to in writing, software      #
# distributed under the License is distributed on an "AS IS" BASIS,        #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. #
# See the License for the specific language governing permissions and      #
# limitations under the License.                                           #
#──────────────────────────────────────────────────────────────────────────#

# usage: install.sh [-n] [--i-have-console] [--check]
PATH=/sbin:/bin:/usr/sbin:/usr/bin
DRY=0; CONSOLE=0; CHECK=0
for a in "$@"; do
	case "$a" in -n) DRY=1 ;; --i-have-console) CONSOLE=1 ;; --check) CHECK=1 ;; esac
done
SHIM_SRC=${SHIM_SRC:-/root/bell-admz/bell-admz-shim.sh}
SHIM=/usr/local/libexec/bell-admz-shim.sh
HOOK=/etc/dhclient-enter-hooks
NATIVE=/usr/local/sbin/pfSense-dhclient-script
die() { echo "ERROR: $*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || die "must be root"
[ -x "$NATIVE" ] || die "$NATIVE not found; unsupported pfSense layout"
grep -q 'dhclient-enter-hooks' "$NATIVE" || die "native script does not source dhclient-enter-hooks; shim cannot work"
grep -q 'rc.newwanip' "$NATIVE" || die "native script has no rc.newwanip reference; unexpected layout"
grep -q 'interface newip' "$NATIVE" || die "native script has no pfSctl 'interface newip' notify; unexpected layout"
if [ "$CHECK" = 1 ]; then
	grep -q 'BELL-ADMZ-HOOK-V1' "$HOOK" 2>/dev/null && echo "hook ok" || die "hook missing"
	[ -x "$SHIM" ] && echo "shim ok" || die "shim missing"
	exit 0
fi
[ "$CONSOLE" = 1 ] || die "re-run with --i-have-console after confirming IPMI/iLO/VGA console access"
[ -f "$SHIM_SRC" ] || die "shim source $SHIM_SRC not found"
if [ -e "$HOOK" ] && ! grep -q 'BELL-ADMZ-HOOK-V1' "$HOOK"; then
	die "$HOOK exists and is not ours; merge manually"
fi

BACKUP="/root/bell-admz-backup-$(date +%Y%m%d-%H%M%S)"
run mkdir -p "$BACKUP"
for f in /sbin/dhclient-script /usr/local/sbin/dhclient-script "$NATIVE" /usr/local/etc/rc.newwanip \
         /etc/rc.newwanip /etc/dhclient.conf /var/etc/dhclient_wan.conf /etc/dhclient-enter-hooks; do
	[ -f "$f" ] && run cp -p "$f" "$BACKUP/$(echo "$f" | tr / _)"
done
[ "$DRY" = 1 ] || sha256 "$BACKUP"/* 2>/dev/null | tee "$BACKUP/SHA256SUMS"

run mkdir -p /usr/local/libexec /var/db/bell-admz /var/run/bell-admz
if [ "$DRY" = 0 ]; then
	T=$(mktemp /usr/local/libexec/.bell.XXXXXX) || die mktemp
	cp "$SHIM_SRC" "$T" && chmod 755 "$T" && mv -f "$T" "$SHIM" || die "shim install"
	T=$(mktemp /etc/.hook.XXXXXX) || die mktemp
	cat > "$T" <<'EOF'
# BELL-ADMZ-HOOK-V1 (managed by bell-admz install.sh; remove with uninstall.sh)
if [ "${interface:-}" = "ix0" ] && [ -x /usr/local/libexec/bell-admz-shim.sh ] \
   && [ ! -e /var/db/bell-admz/DISABLE ] && [ -z "${BELL_ADMZ_ACTIVE:-}" ]; then
	/usr/bin/timeout 20 /usr/local/libexec/bell-admz-shim.sh decide
	if [ "$?" -eq 10 ]; then
		exit 0
	fi
fi
EOF
	chmod 644 "$T" && mv -f "$T" "$HOOK" || die "hook install"
	echo dryrun > /var/db/bell-admz/mode
	sha256 "$SHIM" "$HOOK" | tee "$BACKUP/INSTALLED.SHA256"
else
	echo "[dry-run] install $SHIM and $HOOK, set mode=dryrun"
fi
echo "Installed in DRYRUN mode (logs only). Backup: $BACKUP"
echo "Switch to enforcement only after validation:  echo enforce > /var/db/bell-admz/mode"
echo "Disable instantly:                            touch /var/db/bell-admz/DISABLE"