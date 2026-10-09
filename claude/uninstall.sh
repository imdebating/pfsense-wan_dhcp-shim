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
# uninstall.sh - disables and removes the Bell ADMZ DHCP shim.
# usage: uninstall.sh [-n] [--purge]
#   -n        dry-run
#   --purge   also delete /var/db/bell-admz and the shim log files
# The native pfSense scripts are never modified, so nothing needs restoring;
# backups under /root/bell-admz-backup-* are left in place.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

DRY=0; PURGE=0
for a in "$@"; do
	case "$a" in
	-n) DRY=1 ;;
	--purge) PURGE=1 ;;
	*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

SHIM=/usr/local/libexec/bell-admz-shim.sh
HOOK=/etc/dhclient-enter-hooks
CONF_DIR=/var/db/bell-admz
RUN_DIR=/var/run/bell-admz

run() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || { echo "ERROR: must be root" >&2; exit 1; }

echo "1. bypass the hook"
run mkdir -p "$CONF_DIR"
run touch "$CONF_DIR/DISABLE"

echo "2. flush any pending deferral (runs the native teardown if one is pending)"
if [ -x "$SHIM" ]; then run "$SHIM" flush; fi

echo "3. stop watchdogs"
run /bin/pkill -f 'bell-admz-shim.sh watchdog'

echo "4. remove hook"
if [ -f "$HOOK" ]; then
	if grep -q 'BELL-ADMZ-HOOK-V1' "$HOOK"; then
		run rm -f "$HOOK"
	else
		echo "WARNING: $HOOK is not managed by bell-admz; left in place"
	fi
fi

echo "5. remove shim and runtime state"
run rm -f "$SHIM"
run rm -rf "$RUN_DIR"
run rm -f "$CONF_DIR/DISABLE"

if [ "$PURGE" = 1 ]; then
	echo "6. purge config and logs"
	run rm -rf "$CONF_DIR"
	run rm -f /var/log/bell-admz.log /var/log/bell-admz.log.1
fi

cat <<'EOF'

Uninstalled. Stock pfSense behaviour is restored on the next dhclient event.
If the WAN looks wrong, from the console:
  /usr/local/sbin/dhclient -r ix0
  php -r "require_once('interfaces.inc'); interface_configure('wan', true);"
or use console menu option 2 (set interface IP) / 11 (restart GUI) as needed.
EOF