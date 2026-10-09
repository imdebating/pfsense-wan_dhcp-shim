#!/bin/sh
# Bell ADMZ v2: passive observer only. Invoke under timeout and lockf.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077
set -f
BASE=/usr/local/etc/bell-admz-v2
RUN=/var/run/bell-admz-v2
NATIVE=/usr/local/sbin/pfSense-dhclient-script
EXPECTED=67a689b0855d1ea4f3d4b8e30ae163edb745e0db8c03a672f0542989ff5409cc

log()
{
    message=$(printf '%s' "$*" | /usr/bin/tr '\r\n' '  ' | /usr/bin/cut -c 1-1400)
    /usr/bin/logger -p user.notice -t bell-admz-v2 "decision=NATIVE_ONLY $message" 2>/dev/null || :
}

ipv4()
{
    printf '%s\n' "$1" | /usr/bin/awk '
        BEGIN { ok = 0 }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            n = split($0, a, "."); ok = (n == 4)
            for (i = 1; i <= n; i++) {
                if (length(a[i]) > 3 || a[i] + 0 > 255) ok = 0
            }
        }
        END { exit(ok ? 0 : 1) }
    '
}

if [ "${1-}" = --run ]; then
    [ "$(/usr/bin/id -u)" = 0 ] || exit 77
    [ ! -L "$BASE" ] && [ ! -L "$RUN" ] || exit 65
    [ "$(/usr/bin/stat -f '%u:%Lp' "$BASE" 2>/dev/null)" = 0:700 ] || exit 65
    if [ ! -d "$RUN" ]; then /bin/mkdir -m 700 "$RUN" 2>/dev/null || :; fi
    [ "$(/usr/bin/stat -f '%u:%Lp' "$RUN" 2>/dev/null)" = 0:700 ] || exit 65
    [ ! -L "$RUN/events" ] || exit 65
    if [ ! -d "$RUN/events" ]; then /bin/mkdir -m 700 "$RUN/events" 2>/dev/null || :; fi
    [ "$(/usr/bin/stat -f '%u:%Lp' "$RUN/events" 2>/dev/null)" = 0:700 ] || exit 65
    exec /usr/bin/lockf -k -t 0 "$RUN/observer.lock" \
        /bin/sh "$BASE/bell-admz-observe.sh" --locked "${2-}" "${3-unavailable}"
fi
[ "${1-}" = --locked ] || {
    printf '%s\n' 'Invoke this observer using the installed hook or the documented locked diagnostic command.' >&2
    exit 64
}
phase=${2-}
native_status=${3-unavailable}
case "$phase" in enter|exit|diagnostic) ;; *) exit 64 ;; esac
[ "${interface-}" = ix0 ] || exit 0
[ "$(/usr/bin/id -u)" = 0 ] || exit 77
[ ! -e "$BASE/disabled" ] || { log "phase=$phase detail=disabled"; exit 0; }
[ ! -L "$BASE" ] && [ ! -L "$RUN" ] && [ ! -L "$RUN/events" ] || exit 65
[ "$(/usr/bin/stat -f '%u:%Lp' "$BASE" 2>/dev/null)" = 0:700 ] || exit 65
[ "$(/usr/bin/stat -f '%u:%Lp' "$RUN" 2>/dev/null)" = 0:700 ] || exit 65
[ "$(/usr/bin/stat -f '%u:%Lp' "$RUN/events" 2>/dev/null)" = 0:700 ] || exit 65
[ "$(/bin/cat /etc/version 2>/dev/null)" = 2.9.0-RELEASE ] || {
    log "phase=$phase detail=version_changed"; exit 0;
}
actual=$(/sbin/sha256 -q "$NATIVE" 2>/dev/null) || actual=
[ "$actual" = "$EXPECTED" ] || {
    log "phase=$phase detail=native_checksum_changed_or_unavailable"; exit 0;
}

sequence=0
if [ -f "$RUN/sequence" ]; then
    IFS= read -r sequence < "$RUN/sequence" || :
fi
case "$sequence" in ''|*[!0-9]*) exit 65 ;; esac
[ "$sequence" -lt 1000000000 ] || exit 65
sequence=$((sequence + 1))
temporary=$(/usr/bin/mktemp "$RUN/.sequence.XXXXXXXX") || exit 73
printf '%s\n' "$sequence" > "$temporary" || exit 74
/bin/mv -f "$temporary" "$RUN/sequence" || exit 74
EVENT="$RUN/events/event-$sequence"
/bin/mkdir -m 700 "$EVENT" || exit 73
: > "$EVENT/INCOMPLETE"
REPORT="$EVENT/event.txt"
: > "$REPORT" || exit 73
# Retain up to 200 numbered runtime events, including interrupted events.
expired=$((sequence - 200))
if [ "$expired" -gt 0 ] && [ -d "$RUN/events/event-$expired" ] && [ ! -L "$RUN/events/event-$expired" ]; then
    /bin/rm -rf "$RUN/events/event-$expired"
fi
# Interrupted observations remain available and visibly incomplete.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

record()
{
    name=$1
    value=$(printf '%s' "$2" | /usr/bin/tr '\r\n' '  ' | /usr/bin/cut -c 1-2048)
    printf '%s=%s\n' "$name" "$value" >> "$REPORT"
}

compare()
{
    name=$1; old_present=$2; old=$3; new_present=$4; new=$5
    if [ "$old_present" != x ] || [ "$new_present" != x ]; then
        comparison=UNAVAILABLE
    elif [ "$old" = "$new" ]; then
        if [ -z "$old" ]; then comparison=BOTH_PRESENT_EMPTY; else comparison=RAW_VALUES_EQUAL; fi
    else
        comparison=RAW_VALUES_DIFFERENT
    fi
    record "old_${name}_present" "$old_present"
    record "old_$name" "$old"
    record "new_${name}_present" "$new_present"
    record "new_$name" "$new"
    record "compare_$name" "$comparison"
}

capture()
{
    label=$1; shift
    "$@" > "$EVENT/$label.txt" 2>&1
    status=$?
    record "${label}_status" "$status"
    return 0
}

route_capture()
{
    label=$1; address=$2
    record "${label}_target" "$address"
    if [ "$address" != default ] && ! ipv4 "$address"; then
        record "${label}_status" INVALID_OR_UNAVAILABLE
        return 0
    fi
    capture "$label" /sbin/route -n get -inet "$address"
}

record sequence "$sequence"
record timestamp "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
record boot "$(/sbin/sysctl -n kern.boottime 2>/dev/null)"
record interface "${interface-}"
record reason "${reason-}"
record phase "$phase"
record native_exit_status "$native_status"
record address_family_context inet
record decision NATIVE_PROCESSING_UNCHANGED
record comparison_scope 'raw event values only; no suppression authorization'
log "sequence=$sequence phase=$phase reason=${reason-unavailable} state=STARTED"

compare ip_address "${old_ip_address+x}" "${old_ip_address-}" "${new_ip_address+x}" "${new_ip_address-}"
compare subnet_mask "${old_subnet_mask+x}" "${old_subnet_mask-}" "${new_subnet_mask+x}" "${new_subnet_mask-}"
compare routers "${old_routers+x}" "${old_routers-}" "${new_routers+x}" "${new_routers-}"
compare dhcp_server_identifier "${old_dhcp_server_identifier+x}" "${old_dhcp_server_identifier-}" "${new_dhcp_server_identifier+x}" "${new_dhcp_server_identifier-}"
compare broadcast_address "${old_broadcast_address+x}" "${old_broadcast_address-}" "${new_broadcast_address+x}" "${new_broadcast_address-}"
compare static_routes "${old_static_routes+x}" "${old_static_routes-}" "${new_static_routes+x}" "${new_static_routes-}"
compare classless_routes "${old_classless_routes+x}" "${old_classless_routes-}" "${new_classless_routes+x}" "${new_classless_routes-}"
compare domain_name_servers "${old_domain_name_servers+x}" "${old_domain_name_servers-}" "${new_domain_name_servers+x}" "${new_domain_name_servers-}"
compare domain_name "${old_domain_name+x}" "${old_domain_name-}" "${new_domain_name+x}" "${new_domain_name-}"
compare interface_mtu "${old_interface_mtu+x}" "${old_interface_mtu-}" "${new_interface_mtu+x}" "${new_interface_mtu-}"
record alias_ip_address "${alias_ip_address-}"
record alias_subnet_mask "${alias_subnet_mask-}"
record medium "${medium-}"
record new_dhcp_lease_time "${new_dhcp_lease_time-}"
record new_dhcp_renewal_time "${new_dhcp_renewal_time-}"
record new_dhcp_rebinding_time "${new_dhcp_rebinding_time-}"
log "sequence=$sequence old_ip=[${old_ip_address-}] new_ip=[${new_ip_address-}] old_mask=[${old_subnet_mask-}] new_mask=[${new_subnet_mask-}] old_routers=[${old_routers-}] new_routers=[${new_routers-}] old_server=[${old_dhcp_server_identifier-}] new_server=[${new_dhcp_server_identifier-}]"

capture ifconfig-ix0 /sbin/ifconfig ix0
capture ifconfig-gif0 /sbin/ifconfig gif0
for file in /var/db/ix0_ip /tmp/ix0_router /tmp/ix0_router.last /tmp/ix0_defaultgw
do
    if [ -f "$file" ]; then
        record "$file" "$(/bin/cat "$file" 2>/dev/null)"
    else
        record "$file" ABSENT
    fi
done
route_capture route-default default
cached_gateway=
[ ! -f /tmp/ix0_router ] || IFS= read -r cached_gateway < /tmp/ix0_router || :
route_capture route-cached-gateway "$cached_gateway"
route_capture route-old-server "${old_dhcp_server_identifier-}"
route_capture route-new-server "${new_dhcp_server_identifier-}"
index=0
for gateway in ${old_routers-}
do
    index=$((index + 1)); [ "$index" -le 8 ] || break
    route_capture "route-old-gateway-$index" "$gateway"
done
index=0
for gateway in ${new_routers-}
do
    index=$((index + 1)); [ "$index" -le 8 ] || break
    route_capture "route-new-gateway-$index" "$gateway"
done
monitor=
IFS= read -r monitor < "$BASE/monitor-ipv4" || :
record monitor_source OPERATOR_CONFIGURED_NOT_AUTOMATICALLY_VERIFIED
route_capture route-monitor "$monitor"
record new_route_requirements 'Raw static/classless variables recorded; requirements not interpreted'
capture process-times /bin/ps -axww -o pid=,ppid=,ucomm=,lstart=,etime=
/bin/ps -axww -o pid=,ucomm=,args= | /usr/bin/awk '$2 == "dhclient" || $2 == "dpinger"' > "$EVENT/dhcp-monitor-arguments.txt"
record snapshot_scope 'Independent live lookups; not an atomic kernel-state snapshot'
/bin/rm -f "$EVENT/INCOMPLETE"
log "sequence=$sequence phase=$phase reason=${reason-unavailable} state=COMPLETED event_directory=$EVENT"
exit 0
