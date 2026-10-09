#!/bin/sh
# bell-admz-shim.sh v2.3
# Defers/suppresses pfSense WAN teardown on ix0 when a DHCP re-acquisition
# yields an identical effective WAN state. Fail-open on any uncertainty.
# decide exit codes: 10 = skip native script; anything else = run native script.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

SELF=/usr/local/libexec/bell-admz-shim.sh
NATIVE=/usr/local/sbin/pfSense-dhclient-script
ONLY_IF=ix0
CONF_DIR=/var/db/bell-admz
RUN_DIR=/var/run/bell-admz
LOCK_DIR=$RUN_DIR/lock.d
RECORD=$RUN_DIR/$ONLY_IF.record
PENDING=$RUN_DIR/$ONLY_IF.pending
LOGFILE=/var/log/bell-admz.log
NATIVE_HASH_FILE=$CONF_DIR/native.sha256
DEFER_MAX=15
LOCK_WAIT=5
HELD=0
MODE=off
# Variables supplied by dhclient in the environment (empty when run by hand)
interface=${interface:-}
reason=${reason:-}
medium=${medium:-}
alias_ip_address=${alias_ip_address:-}
old_ip_address=${old_ip_address:-}
old_subnet_mask=${old_subnet_mask:-}
old_routers=${old_routers:-}
old_classless_routes=${old_classless_routes:-}
old_static_routes=${old_static_routes:-}
new_ip_address=${new_ip_address:-}
new_subnet_mask=${new_subnet_mask:-}
new_routers=${new_routers:-}
new_broadcast_address=${new_broadcast_address:-}
new_domain_name_servers=${new_domain_name_servers:-}
new_domain_name=${new_domain_name:-}
new_dhcp_server_identifier=${new_dhcp_server_identifier:-}
new_classless_routes=${new_classless_routes:-}
new_static_routes=${new_static_routes:-}

log() {
	/usr/bin/logger -t bell-admz -p user.notice "$*"
	printf '%s bell-admz[%s]: %s\n' "$(/bin/date '+%b %e %T')" "$$" "$*" >> "$LOGFILE" 2>/dev/null
}

rotate_log() {
	[ -f "$LOGFILE" ] || return 0
	_sz=$(/usr/bin/stat -f %z "$LOGFILE" 2>/dev/null) || return 0
	case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$_sz" -gt 524288 ]; then /bin/mv -f "$LOGFILE" "$LOGFILE.1"; fi
	return 0
}

log_env() {
	_e=$(/usr/bin/env | /usr/bin/grep -E '^(reason|interface|medium|old_|new_|alias_)' \
	  | /usr/bin/tr -cd '[:print:]\n' | /usr/bin/tr '\n' ' ')
	log "ENV $_e"
}

san() { printf '%s' "$1" | /usr/bin/tr -cd 'A-Za-z0-9._:, -'; }

verify_native() {
	[ -r "$NATIVE_HASH_FILE" ] || { log "native script hash not approved; shim inert (run: $SELF approve)"; return 1; }
	_want=
	read -r _want < "$NATIVE_HASH_FILE"
	_have=$(/sbin/sha256 -q "$NATIVE" 2>/dev/null)
	if [ -z "$_have" ] || [ "$_have" != "$_want" ]; then
		log "native script hash changed (have=$_have approved=$_want); shim inert until re-approved after compat check"
		return 1
	fi
	return 0
}

cfg_load() {
	[ -r "$CONF_DIR/shim.conf" ] || return 0
	while IFS='=' read -r _k _v; do
		case "$_k" in
		DEFER_MAX)
			case "$_v" in
			''|*[!0-9]*) ;;
			*) if [ "$_v" -ge 5 ] && [ "$_v" -le 120 ]; then DEFER_MAX=$_v; fi ;;
			esac ;;
		esac
	done < "$CONF_DIR/shim.conf"
}

get_mode() {
	MODE=off
	[ -e "$CONF_DIR/DISABLE" ] && return 0
	[ -r "$CONF_DIR/mode" ] || return 0
	_m=
	read -r _m < "$CONF_DIR/mode"
	case "$_m" in dryrun|enforce) MODE=$_m ;; esac
	return 0
}

valid_ipv4() {
	case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
	_bad=$(printf '%s' "$1" | /usr/bin/awk -F. \
	  'NF!=4{print "x"; exit} {for(i=1;i<=4;i++) if(length($i)>3||$i+0>255){print "x"; exit}}')
	[ -z "$_bad" ]
}

hex_to_dotted() {
	case "$1" in
	0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
	*) return 1 ;;
	esac
	_h=$1
	printf '%d.%d.%d.%d' $(( (_h >> 24) & 255 )) $(( (_h >> 16) & 255 )) \
	    $(( (_h >> 8) & 255 )) $(( _h & 255 ))
}

kv_get() { /usr/bin/awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$1" 2>/dev/null; }

kv_write() { # $1=dest, remaining = key=value pairs; atomic replace
	_dest=$1; shift
	_tmp=$(/usr/bin/mktemp "$RUN_DIR/.tmp.XXXXXX") || return 1
	: > "$_tmp"
	for _kv in "$@"; do printf '%s\n' "$_kv" >> "$_tmp"; done
	/bin/chmod 600 "$_tmp"
	/bin/mv -f "$_tmp" "$_dest"
}

acquire_lock() {
	/bin/mkdir -p "$RUN_DIR" 2>/dev/null || return 1
	_i=0
	while ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; do
		if [ -r "$LOCK_DIR/pid" ]; then
			read -r _p < "$LOCK_DIR/pid"
			if [ -n "$_p" ] && ! /bin/kill -0 "$_p" 2>/dev/null; then
				/bin/rm -rf "$LOCK_DIR"
				continue
			fi
		fi
		_i=$((_i + 1))
		[ "$_i" -ge "$LOCK_WAIT" ] && return 1
		/bin/sleep 1
	done
	printf '%s\n' "$$" > "$LOCK_DIR/pid"
	HELD=1
	return 0
}
release_lock() { [ "$HELD" -eq 1 ] && /bin/rm -rf "$LOCK_DIR"; HELD=0; }
trap 'release_lock' EXIT

live_state() { # sets L_IP L_MASK; fails unless exactly one inet address
	L_IP=; L_MASK=
	_o=$(/sbin/ifconfig "$ONLY_IF" inet 2>/dev/null) || return 1
	_r=$(printf '%s\n' "$_o" | /usr/bin/awk '$1=="inet"{c++; ip=$2; for(i=3;i<=NF;i++) if($i=="netmask") m=$(i+1)} END{if(c==1) print ip, m}')
	[ -n "$_r" ] || return 1
	set -- $_r
	valid_ipv4 "$1" || return 1
	L_IP=$1
	L_MASK=$(hex_to_dotted "$2") || return 1
	return 0
}

route_get() { # sets R_IF R_GW
	R_IF=; R_GW=
	_o=$(/sbin/route -n get -inet "$1" 2>/dev/null) || return 1
	R_IF=$(printf '%s\n' "$_o" | /usr/bin/awk '$1=="interface:"{print $2; exit}')
	R_GW=$(printf '%s\n' "$_o" | /usr/bin/awk '$1=="gateway:"{print $2; exit}')
	[ -n "$R_IF" ]
}

find_monitor() { # $1 = WAN IPv4; prints the dpinger target bound to it
	/bin/ps -axww -o command= 2>/dev/null | /usr/bin/awk -v ip="$1" \
	  '/dpinger/ {b=""; for(i=1;i<=NF;i++) if($i=="-B") b=$(i+1); if(b==ip){print $NF; exit}}'
}

routes_ok() { # $1=gateway $2=monitor
	valid_ipv4 "$1" && valid_ipv4 "$2" || { log "routes: gateway/monitor unavailable gw='$1' mon='$2'"; return 1; }
	route_get default || return 1
	if [ "$R_IF" != "$ONLY_IF" ] || [ "$R_GW" != "$1" ]; then
		log "routes: default via if=$R_IF gw=$R_GW (expected $ONLY_IF $1)"; return 1
	fi
	route_get "$1" || return 1
	[ "$R_IF" = "$ONLY_IF" ] || { log "routes: gateway $1 via $R_IF"; return 1; }
	route_get "$2" || return 1
	if [ "$R_IF" != "$ONLY_IF" ]; then log "routes: monitor $2 via $R_IF"; return 1; fi
	case "$R_GW" in
	"$1"|link#*) return 0 ;;
	esac
	[ "$2" = "$1" ] && return 0
	log "routes: monitor $2 gateway=$R_GW (expected $1)"
	return 1
}

state_files_ok() { # $1=ip $2=routers (sanitised, as stored)
	_fr=; _fi=
	[ -r "/tmp/${ONLY_IF}_router" ] && read -r _fr < "/tmp/${ONLY_IF}_router"
	[ -r "/var/db/${ONLY_IF}_ip" ] && read -r _fi < "/var/db/${ONLY_IF}_ip"
	if [ "$(san "$_fr")" != "$2" ] || [ "$_fi" != "$1" ]; then
		log "state files: /tmp/${ONLY_IF}_router='$_fr' /var/db/${ONLY_IF}_ip='$_fi' (expected '$2' '$1')"
		return 1
	fi
	[ -f "/tmp/${ONLY_IF}_defaultgw" ] || log "note: /tmp/${ONLY_IF}_defaultgw absent (native script will not manage the default route)"
	return 0
}

unsupported_opts() { [ -n "${1:-}" ] || [ -n "${2:-}" ] || [ -n "${3:-}" ]; }

pend_load() {
	[ -r "$PENDING" ] || return 1
	P_TOKEN=$(kv_get "$PENDING" token);     P_EPOCH=$(kv_get "$PENDING" epoch)
	P_DRY=$(kv_get "$PENDING" dry);         P_IF=$(kv_get "$PENDING" iface)
	P_IP=$(kv_get "$PENDING" ip);           P_MASK=$(kv_get "$PENDING" mask)
	P_ROUTERS=$(kv_get "$PENDING" routers); P_BCAST=$(kv_get "$PENDING" bcast)
	P_SERVER=$(kv_get "$PENDING" server);   P_DNS=$(kv_get "$PENDING" dns)
	P_DOMAIN=$(kv_get "$PENDING" domain);   P_MON=$(kv_get "$PENDING" monitor)
	P_MEDIUM=$(kv_get "$PENDING" medium)
	case "$P_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
	return 0
}

teardown_pending() { # replay the native EXPIRE path with the saved old_* values
	if [ ! -x "$NATIVE" ]; then log "ERROR native script $NATIVE missing"; return 1; fi
	log "teardown: native EXPIRE with saved state if=$P_IF ip=$P_IP mask=$P_MASK routers=$P_ROUTERS medium='$P_MEDIUM'"
	/usr/bin/timeout 30 /usr/bin/env BELL_ADMZ_ACTIVE=1 \
	  -u new_ip_address -u new_subnet_mask -u new_routers -u new_broadcast_address \
	  -u new_domain_name_servers -u new_dhcp_server_identifier \
	  -u new_classless_routes -u new_static_routes \
	  reason=EXPIRE interface="$P_IF" old_ip_address="$P_IP" old_subnet_mask="$P_MASK" \
	  old_routers="$P_ROUTERS" old_broadcast_address="$P_BCAST" \
	  old_classless_routes= old_static_routes= alias_ip_address= medium="$P_MEDIUM" "$NATIVE"
	_rc=$?
	log "teardown: native exit status $_rc"
	return $_rc
}

flush_pending() {
	if pend_load; then
		[ "$P_DRY" = "1" ] || teardown_pending
	fi
	/bin/rm -f "$PENDING"
}

record_update() {
	_g=
	if valid_ipv4 "${new_ip_address:-}" && valid_ipv4 "${new_subnet_mask:-}"; then
		set -- ${new_routers:-}
		_g=${1:-}
	fi
	if valid_ipv4 "${new_ip_address:-}" && valid_ipv4 "${new_subnet_mask:-}" && valid_ipv4 "$_g" \
	   && valid_ipv4 "${new_dhcp_server_identifier:-}"; then
		kv_write "$RECORD" "iface=$interface" "ip=$new_ip_address" "mask=$new_subnet_mask" \
		  "routers=$(san "$new_routers")" "gw=$_g" "bcast=$(san "${new_broadcast_address:-}")" \
		  "server=$new_dhcp_server_identifier" "dns=$(san "${new_domain_name_servers:-}")" \
		  "domain=$(san "${new_domain_name:-}")" "epoch=$(/bin/date +%s)"
		log "record: saved ip=$new_ip_address mask=$new_subnet_mask routers=$new_routers server=$new_dhcp_server_identifier"
	else
		/bin/rm -f "$RECORD"
		log "record: new lease data incomplete/malformed (server-id='${new_dhcp_server_identifier:-}'); record cleared (next EXPIRE takes normal path)"
	fi
}

h_expire() {
	if [ -e "$PENDING" ]; then
		log "EXPIRE: stale pending state found; flushing and using normal path"
		flush_pending; return 0
	fi
	if [ ! -r "$RECORD" ]; then
		log "EXPIRE: no previous state (first run or reboot) -> normal path"; return 0
	fi
	if unsupported_opts "${old_classless_routes:-}" "${old_static_routes:-}" "${alias_ip_address:-}"; then
		log "EXPIRE: classless/static routes or alias present (unsupported) -> normal path"; return 0
	fi
	C_IP=$(kv_get "$RECORD" ip); C_MASK=$(kv_get "$RECORD" mask); C_ROUT=$(kv_get "$RECORD" routers)
	C_GW=$(kv_get "$RECORD" gw); C_SRV=$(kv_get "$RECORD" server); C_BC=$(kv_get "$RECORD" bcast)
	C_DNS=$(kv_get "$RECORD" dns); C_DOM=$(kv_get "$RECORD" domain)
	set -- ${old_routers:-}
	E_GW=${1:-}
	log "EXPIRE compare if=$interface env(ip=${old_ip_address:-} mask=${old_subnet_mask:-} routers=${old_routers:-}) record(ip=$C_IP mask=$C_MASK routers=$C_ROUT server=$C_SRV)"
	if ! valid_ipv4 "${old_ip_address:-}" || ! valid_ipv4 "${old_subnet_mask:-}" || ! valid_ipv4 "$E_GW"; then
		log "EXPIRE: old_* missing/malformed -> normal path"; return 0
	fi
	if [ "${old_ip_address}" != "$C_IP" ] || [ "${old_subnet_mask}" != "$C_MASK" ] \
	   || [ "$(san "$old_routers")" != "$C_ROUT" ]; then
		log "EXPIRE: env differs from record -> normal path"; return 0
	fi
	if ! live_state; then log "EXPIRE: live interface state undeterminable -> normal path"; return 0; fi
	if [ "$L_IP" != "$C_IP" ] || [ "$L_MASK" != "$C_MASK" ]; then
		log "EXPIRE: live ip/mask ($L_IP/$L_MASK) differ from record -> normal path"; return 0
	fi
	if ! state_files_ok "$C_IP" "$C_ROUT"; then log "EXPIRE: native state files mismatch -> normal path"; return 0; fi
	_mon=$(find_monitor "$L_IP")
	if ! routes_ok "$C_GW" "$_mon"; then log "EXPIRE: route state unavailable/mismatched -> normal path"; return 0; fi
	_tok="$$.$(/bin/date +%s)"
	_dry=0; [ "$MODE" = "dryrun" ] && _dry=1
	kv_write "$PENDING" "token=$_tok" "epoch=$(/bin/date +%s)" "dry=$_dry" "iface=$interface" \
	  "ip=$C_IP" "mask=$C_MASK" "routers=$C_ROUT" "bcast=$C_BC" "server=$C_SRV" \
	  "dns=$C_DNS" "domain=$C_DOM" "monitor=$_mon" "medium=$(san "${medium:-}")" \
	  || { log "EXPIRE: cannot write pending -> normal path"; return 0; }
	if [ "$_dry" = "1" ]; then
		log "DRYRUN EXPIRE: would defer teardown (monitor=$_mon gw=$C_GW)"; return 0
	fi
	if ! /usr/sbin/daemon -f "$SELF" watchdog "$_tok"; then
		/bin/rm -f "$PENDING"; log "EXPIRE: watchdog start failed -> normal path"; return 0
	fi
	log "EXPIRE: teardown DEFERRED up to ${DEFER_MAX}s (monitor=$_mon gw=$C_GW token=$_tok)"
	return 10
}

h_preinit() {
	pend_load || return 0
	[ "$P_DRY" = "1" ] && return 0
	_age=$(( $(/bin/date +%s) - P_EPOCH ))
	if [ "$_age" -le $((DEFER_MAX + 10)) ]; then
		log "PREINIT: skipped while deferral pending (age ${_age}s)"; return 10
	fi
	return 0
}

h_bound() {
	if ! pend_load; then record_update; return 0; fi
	_age=$(( $(/bin/date +%s) - P_EPOCH ))
	set -- ${new_routers:-}
	_ngw=${1:-}
	_same=1
	[ "$interface" = "$P_IF" ] && [ "${new_ip_address:-}" = "$P_IP" ] && [ "${new_subnet_mask:-}" = "$P_MASK" ] \
	  && [ "$(san "${new_routers:-}")" = "$P_ROUTERS" ] \
	  && [ "${new_dhcp_server_identifier:-}" = "$P_SERVER" ] \
	  && [ "$(san "${new_domain_name_servers:-}")" = "$P_DNS" ] \
	  && [ "$(san "${new_domain_name:-}")" = "$P_DOMAIN" ] || _same=0
	log "BOUND compare if=$interface ip $P_IP->${new_ip_address:-} mask $P_MASK->${new_subnet_mask:-} routers '$P_ROUTERS'->'${new_routers:-}' server $P_SERVER->${new_dhcp_server_identifier:-} dns '$P_DNS'->'$(san "${new_domain_name_servers:-}")' domain '$P_DOMAIN'->'$(san "${new_domain_name:-}")' monitor=$P_MON age=${_age}s same=$_same"
	if [ "$P_DRY" = "1" ]; then
		log "DRYRUN BOUND: would $( [ "$_same" = 1 ] && echo SKIP || echo 'run NORMAL path')"
		/bin/rm -f "$PENDING"; record_update; return 0
	fi
	if [ "$_age" -gt $((DEFER_MAX + 10)) ]; then
		log "BOUND: deferral expired (age ${_age}s) -> teardown then normal path"
		teardown_pending; /bin/rm -f "$PENDING"; record_update; return 0
	fi
	_ok=$_same
	if [ "$_ok" = 1 ]; then
		valid_ipv4 "${new_ip_address:-}" && valid_ipv4 "${new_subnet_mask:-}" && valid_ipv4 "$_ngw" \
		  && valid_ipv4 "${new_dhcp_server_identifier:-}" && valid_ipv4 "$P_SERVER" || _ok=0
	fi
	if [ "$_ok" = 1 ] && unsupported_opts "${new_classless_routes:-}" "${new_static_routes:-}" "${alias_ip_address:-}"; then
		log "BOUND: classless/static routes or alias present -> normal path"; _ok=0
	fi
	if [ "$_ok" = 1 ]; then
		live_state && [ "$L_IP" = "$P_IP" ] && [ "$L_MASK" = "$P_MASK" ] \
		  && state_files_ok "$P_IP" "$P_ROUTERS" && routes_ok "$_ngw" "$P_MON" || _ok=0
	fi
	if [ "$_ok" = 1 ]; then
		/bin/rm -f "$PENDING"; record_update
		log "BOUND: effective WAN state UNCHANGED -> native script skipped (no rc.newwanip)"
		return 10
	fi
	log "BOUND: state changed or uncertain -> native teardown then native BOUND"
	teardown_pending; /bin/rm -f "$PENDING"; record_update
	return 0
}

h_other() {
	case "${reason:-}" in
	ARPCHECK|ARPSEND|MEDIUM) return 0 ;;
	esac
	if [ -e "$PENDING" ]; then
		log "reason=${reason:-?} while deferral pending -> native teardown then native path"
		flush_pending
	fi
	case "${reason:-}" in RENEW|REBIND|REBOOT) record_update ;; esac
	return 0
}

cmd_decide() {
	rotate_log; cfg_load; get_mode
	if [ "${interface:-}" != "$ONLY_IF" ]; then return 0; fi
	if [ "$MODE" = "dryrun" ]; then log_env; fi
	if [ "$MODE" != "off" ] && ! verify_native; then MODE=off; fi
	if [ "$MODE" = "off" ]; then
		[ -e "$PENDING" ] && { acquire_lock; flush_pending; release_lock; }
		return 0
	fi
	acquire_lock || { log "lock timeout reason=${reason:-?} -> normal path"; return 0; }
	case "${reason:-}" in
	EXPIRE) h_expire; _r=$? ;;
	PREINIT) h_preinit; _r=$? ;;
	BOUND) h_bound; _r=$? ;;
	*) h_other; _r=$? ;;
	esac
	release_lock
	[ "$MODE" = "dryrun" ] && [ "$_r" -eq 10 ] && _r=0
	return $_r
}

cmd_watchdog() {
	cfg_load
	/bin/sleep "$DEFER_MAX"
	acquire_lock || log "watchdog: lock timeout; proceeding without lock"
	if pend_load && [ "$P_TOKEN" = "$1" ]; then
		log "watchdog: deferral expired without matching BOUND -> native teardown"
		[ "$P_DRY" = "1" ] || teardown_pending
		/bin/rm -f "$PENDING"
	fi
	release_lock
	return 0
}

cmd_flush() { acquire_lock; flush_pending; release_lock; log "flush: done"; }

cmd_approve() {
	_h=$(/sbin/sha256 -q "$NATIVE" 2>/dev/null)
	[ -n "$_h" ] || { echo "cannot hash $NATIVE" >&2; return 1; }
	/bin/mkdir -p "$CONF_DIR"
	printf '%s\n' "$_h" > "$CONF_DIR/native.sha256.tmp" \
	  && /bin/mv -f "$CONF_DIR/native.sha256.tmp" "$NATIVE_HASH_FILE" || return 1
	log "approved native script sha256 $_h"
	echo "approved $_h"
}

cmd_mode() {
	case "${1:-}" in dryrun|enforce|off) ;; *) echo "usage: $0 mode dryrun|enforce|off" >&2; return 2 ;; esac
	if [ "$1" != "off" ] && ! verify_native; then
		echo "native script not approved/changed; run compat check, then: $0 approve" >&2; return 1
	fi
	/bin/mkdir -p "$CONF_DIR"
	printf '%s\n' "$1" > "$CONF_DIR/mode.tmp" && /bin/mv -f "$CONF_DIR/mode.tmp" "$CONF_DIR/mode" || return 1
	log "mode set to $1"
	echo "mode=$1"
}

cmd_disable() {
	/bin/mkdir -p "$CONF_DIR"
	: > "$CONF_DIR/DISABLE"
	acquire_lock; flush_pending; release_lock
	log "disabled via DISABLE flag"
	echo "disabled (hook bypassed; native pfSense behaviour restored)"
}

cmd_enable() { /bin/rm -f "$CONF_DIR/DISABLE"; log "DISABLE flag removed"; echo "enabled (mode=$(cat $CONF_DIR/mode 2>/dev/null))"; }

cmd_status() {
	cfg_load; get_mode
	echo "mode(effective)=$MODE configured=$(cat $CONF_DIR/mode 2>/dev/null || echo none) DEFER_MAX=$DEFER_MAX"
	echo "disabled=$([ -e $CONF_DIR/DISABLE ] && echo yes || echo no)"
	if verify_native 2>/dev/null; then echo "native script: approved"; else echo "native script: NOT approved / changed"; fi
	echo "pending: $(cat $PENDING 2>/dev/null | tr '\n' ' ' || echo none)"
	echo "--- last log lines ---"; /usr/bin/tail -n 15 "$LOGFILE" 2>/dev/null
}

cmd_diag() {
	cfg_load; get_mode
	echo "== shim =="; echo "version=$(cat /etc/version 2>/dev/null) mode=$MODE DEFER_MAX=$DEFER_MAX disable_flag=$([ -e $CONF_DIR/DISABLE ] && echo yes || echo no)"
	echo "native sha256: $(/sbin/sha256 -q $NATIVE 2>/dev/null) approved: $(cat $NATIVE_HASH_FILE 2>/dev/null || echo none)"
	echo "== hook/native sanity =="
	[ -x "$NATIVE" ] && echo "native: present" || echo "native: MISSING"
	grep -q 'dhclient-enter-hooks' "$NATIVE" 2>/dev/null && echo "native sources dhclient-enter-hooks: yes" || echo "native sources dhclient-enter-hooks: NO (shim inert)"
	grep -q 'interface newip' "$NATIVE" 2>/dev/null && echo "native notifies via pfSctl interface newip: yes" || echo "native notify: NOT FOUND"
	grep -q 'BELL-ADMZ-HOOK-V1' /etc/dhclient-enter-hooks 2>/dev/null && echo "hook installed: yes" || echo "hook installed: no"
	echo "== live state =="
	if live_state; then echo "ip=$L_IP mask=$L_MASK"; else echo "live state: UNDETERMINABLE"; fi
	_m=$(find_monitor "${L_IP:-}"); echo "dpinger monitor: ${_m:-not found}"
	route_get default && echo "default: if=$R_IF gw=$R_GW"
	[ -n "$R_GW" ] && route_get "$R_GW" && echo "gateway route: if=$R_IF"
	[ -n "${_m:-}" ] && route_get "$_m" && echo "monitor route: if=$R_IF gw=$R_GW"
	echo "== native state files =="
	for f in /tmp/${ONLY_IF}_router /tmp/${ONLY_IF}_router.last /tmp/${ONLY_IF}_defaultgw /var/db/${ONLY_IF}_ip; do
		printf '%s: ' "$f"; cat "$f" 2>/dev/null || echo "(absent)"
	done
	echo "== record =="; cat "$RECORD" 2>/dev/null || echo "none"
	echo "== pending =="; cat "$PENDING" 2>/dev/null || echo "none"
	echo "== lease file =="; /usr/bin/tail -n 25 /var/db/dhclient.leases.$ONLY_IF 2>/dev/null
	return 0
}

case "${1:-}" in
decide)   cmd_decide; exit $? ;;
watchdog) cmd_watchdog "${2:-}"; exit 0 ;;
flush)    cmd_flush; exit 0 ;;
approve)  cmd_approve; exit $? ;;
mode)     cmd_mode "${2:-}"; exit $? ;;
disable)  cmd_disable; exit 0 ;;
enable)   cmd_enable; exit 0 ;;
status)   cmd_status; exit 0 ;;
diag)     cmd_diag; exit 0 ;;
*) echo "usage: $0 decide|watchdog <token>|flush|approve|mode <dryrun|enforce|off>|disable|enable|status|diag" >&2; exit 2 ;;
esac