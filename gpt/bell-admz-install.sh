#!/bin/sh
# Installs passive observers, never an active DHCP suppression shim.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077
BASE=/usr/local/etc/bell-admz-v2
RUN=/var/run/bell-admz-v2
NATIVE=/usr/local/sbin/pfSense-dhclient-script
EXPECTED=67a689b0855d1ea4f3d4b8e30ae163edb745e0db8c03a672f0542989ff5409cc

usage()
{
    printf '%s\n' 'Usage:' \
        '  bell-admz-install.sh --dry-run ABSOLUTE_SOURCE_DIRECTORY MONITOR_IPV4' \
        '  bell-admz-install.sh --install ABSOLUTE_SOURCE_DIRECTORY MONITOR_IPV4 --console-confirmed' >&2
    exit 64
}
mode=${1-}; SOURCE=${2-}; monitor=${3-}
case "$mode" in
    --dry-run) [ "$#" -eq 3 ] || usage ;;
    --install) [ "$#" -eq 4 ] && [ "$4" = --console-confirmed ] || usage ;;
    *) usage ;;
esac
[ "$(/usr/bin/id -u)" = 0 ] || exit 77
case "$SOURCE" in /*) ;; *) usage ;; esac
# Serialize administrative publication; the lock file is deliberately retained.
if [ "${BELL_ADMZ_ADMIN_LOCKED-}" != yes ]; then
    BELL_ADMZ_ADMIN_LOCKED=yes
    export BELL_ADMZ_ADMIN_LOCKED
    exec /bin/timeout -k 1 30 /usr/bin/lockf -k -t 0 \
        /var/run/bell-admz-v2-admin.lock /bin/sh "$0" "$@"
fi
for executable in /bin/timeout /usr/bin/lockf /usr/bin/logger /usr/bin/stat /usr/bin/mktemp /usr/bin/cmp /usr/bin/awk /sbin/sha256 /sbin/sysctl /sbin/ifconfig /sbin/route /bin/ps
do
    [ -x "$executable" ] || { printf 'Missing executable: %s\n' "$executable" >&2; exit 69; }
done
[ "$(/bin/cat /etc/version 2>/dev/null)" = 2.9.0-RELEASE ] || {
    printf '%s\n' 'Refusing: expected pfSense 2.9.0-RELEASE.' >&2; exit 65;
}
[ -f "$NATIVE" ] && [ ! -L "$NATIVE" ] || exit 65
[ "$(/sbin/sha256 -q "$NATIVE")" = "$EXPECTED" ] || {
    printf '%s\n' 'Native DHCP script checksum differs from supplied diagnostics; review the current source.' >&2; exit 65;
}
/bin/sh -n "$NATIVE" || exit 65
# Verify that both exact sourced hook references exist. No patch is attempted.
for hook in /etc/dhclient-enter-hooks /etc/dhclient-exit-hooks
do
    /usr/bin/grep -E -q "^[[:space:]]*[.][[:space:]]+$hook([[:space:]]|$)" "$NATIVE" || {
        printf 'Required sourced hook reference not found: %s\n' "$hook" >&2; exit 65;
    }
    if [ -e "$hook" ] || [ -L "$hook" ]; then
        printf 'Existing hook will not be overwritten: %s\n' "$hook" >&2; exit 65;
    fi
done
for directory in "$BASE" "$RUN"
do
    if [ -e "$directory" ] || [ -L "$directory" ]; then
        printf 'Existing path requires review/archive first: %s\n' "$directory" >&2; exit 65;
    fi
done
for name in bell-admz-observe.sh bell-admz-uninstall.sh
do
    [ -f "$SOURCE/$name" ] || exit 66
    /bin/sh -n "$SOURCE/$name" || exit 65
done
printf '%s\n' "$monitor" | /usr/bin/awk '
    BEGIN { ok = 0 }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        n = split($0, a, "."); ok = (n == 4)
        for (i = 1; i <= n; i++) if (length(a[i]) > 3 || a[i] + 0 > 255) ok = 0
    }
    END { exit(ok ? 0 : 1) }
' || { printf '%s\n' 'Invalid monitor IPv4 address.' >&2; exit 65; }
# Exercise only read-only utility behaviour, not DHCP events.
/bin/timeout -k 1 2 /usr/bin/lockf -k -t 0 /var/run/bell-admz-v2-preflight.lock /bin/sh -c ':' || exit 69
/bin/ps -axww -o pid=,ucomm=,args= >/dev/null || exit 69
printf 'Target: pfSense 2.9.0-RELEASE\nNative checksum: %s\nMonitor: %s\nMode: passive observation only\n' "$EXPECTED" "$monitor"
[ "$mode" = --install ] || { printf '%s\n' 'Preflight passed. No hooks installed. Administrative/preflight lock files may exist.'; exit 0; }

BACKUP="/root/bell-admz-backup-$(/bin/date +%Y%m%d-%H%M%S)-$$"
/bin/mkdir -m 700 "$BACKUP" || exit 73
backup()
{
    file=$1; [ -f "$file" ] || return 0
    target="$BACKUP/files$file"
    /bin/mkdir -p "${target%/*}" && /bin/cp -p "$file" "$target"
}
for file in /sbin/dhclient /sbin/dhclient-script /usr/local/sbin/dhclient-script /usr/local/sbin/pfSense-dhclient-script /etc/rc.newwanip /usr/local/etc/rc.newwanip /etc/dhclient.conf /etc/rc.linkup /usr/local/etc/rc.linkup
do
    backup "$file" || exit 74
done
for file in /var/etc/dhclient*
do
    [ -f "$file" ] || continue
    backup "$file" || exit 74
done
/usr/bin/find "$BACKUP/files" -type f -exec /sbin/sha256 '{}' \; > "$BACKUP/checksums.txt" || exit 74
/bin/mkdir -m 700 "$BASE" || exit 73
/bin/mkdir -m 700 "$RUN" || exit 73
/bin/mkdir -m 700 "$RUN/events" || exit 73
printf '%s\n' bell-admz-observer-v2 > "$BASE/installation-id"
printf '%s\n' "$BACKUP" > "$BASE/backup-path"
printf '%s\n' "$EXPECTED" > "$BASE/native.sha256"
printf '%s\n' "$monitor" > "$BASE/monitor-ipv4"
: > "$BASE/disabled"
for name in bell-admz-observe.sh bell-admz-uninstall.sh
do
    temporary=$(/usr/bin/mktemp "$BASE/.install.XXXXXXXX") || exit 73
    /bin/cp "$SOURCE/$name" "$temporary" || exit 74
    /usr/sbin/chown 0:0 "$temporary" || exit 74
    /bin/chmod 700 "$temporary" || exit 74
    /bin/mv -f "$temporary" "$BASE/$name" || exit 74
done
write_hook()
{
    phase=$1; destination=$2
    {
        printf '%s\n' '#!/bin/sh' '# Managed Bell ADMZ observer v2; no DHCP suppression' '('
        printf "    bell_phase='%s'\n" "$phase"
        /bin/cat <<'HOOK'
    PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
    export PATH
    if [ "${interface-}" = ix0 ] && [ ! -e /usr/local/etc/bell-admz-v2/disabled ]; then
        export interface reason
        export old_ip_address new_ip_address old_subnet_mask new_subnet_mask
        export old_routers new_routers old_dhcp_server_identifier new_dhcp_server_identifier
        export old_broadcast_address new_broadcast_address
        export old_static_routes new_static_routes old_classless_routes new_classless_routes
        export old_domain_name_servers new_domain_name_servers old_domain_name new_domain_name
        export old_interface_mtu new_interface_mtu alias_ip_address alias_subnet_mask medium
        export new_dhcp_lease_time new_dhcp_renewal_time new_dhcp_rebinding_time
        if [ -x /bin/timeout ] && [ -x /usr/bin/lockf ] &&
           [ -f /usr/local/etc/bell-admz-v2/bell-admz-observe.sh ]; then
            /bin/timeout -k 1 2 \
                /bin/sh /usr/local/etc/bell-admz-v2/bell-admz-observe.sh \
                --run "$bell_phase" "${exit_status-unavailable}" >/dev/null 2>&1
            bell_status=$?
            if [ "$bell_status" -ne 0 ]; then
                /bin/timeout -k 1 1 /usr/bin/logger -p user.notice -t bell-admz-v2 \
                    "decision=NATIVE_ONLY phase=$bell_phase observer_status=$bell_status" >/dev/null 2>&1 || :
            fi
        fi
    fi
) || :
:
HOOK
    } > "$destination"
}
write_hook enter "$BASE/enter-hook.expected" || exit 74
write_hook exit "$BASE/exit-hook.expected" || exit 74
/bin/sh -n "$BASE/enter-hook.expected" || exit 65
/bin/sh -n "$BASE/exit-hook.expected" || exit 65
publish()
{
    expected=$1; target=$2
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
    temporary=$(/usr/bin/mktemp /etc/.bell-admz-v2.XXXXXXXX) || return 1
    /bin/cp "$expected" "$temporary" && /usr/sbin/chown 0:0 "$temporary" && /bin/chmod 600 "$temporary" || {
        /bin/rm -f "$temporary"; return 1;
    }
    /bin/mv -f "$temporary" "$target"
}
# An interrupted install remains disabled and can be rolled back by uninstall.
publish "$BASE/exit-hook.expected" /etc/dhclient-exit-hooks || exit 74
publish "$BASE/enter-hook.expected" /etc/dhclient-enter-hooks || exit 74
# Recheck the native file before enabling observation.
[ "$(/sbin/sha256 -q "$NATIVE")" = "$EXPECTED" ] || exit 65
/bin/rm -f "$BASE/disabled" || exit 74
printf 'Installed passive hooks. Backup: %s\n' "$BACKUP"
printf '%s\n' 'No native files changed. No WAN/DHCP/service restart performed.'
exit 0
