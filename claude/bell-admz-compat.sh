#!/bin/sh
# bell-admz-compat.sh - read-only check that the installed pfSense dhclient
# script and base tools match what the shim depends on.
# usage: bell-admz-compat.sh [path-to-dhclient-script]
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
S=${1:-/usr/local/sbin/pfSense-dhclient-script}
FAIL=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
need() {
	if /usr/bin/grep -q -F -e "$2" "$S"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

echo "== environment =="
echo "version: $(cat /etc/version 2>/dev/null)"
echo "owner: $(pkg which "$S" 2>&1)"
echo "sha256: $(sha256 -q "$S" 2>/dev/null)"
[ -r "$S" ] || { echo "FAIL  cannot read $S"; exit 1; }

echo "== native script anchors =="
need "hook presence test"        'if [ -f /etc/dhclient-enter-hooks ]; then'
need "hook sourced with dot"     '. /etc/dhclient-enter-hooks'
need "hook abort test"           'if [ $exit_status -ne 0 ]; then'
need "exit_status initialised"   'exit_status=0'
need "final exit uses status"    'exit $exit_status'
need "notify via pfSctl"         '/usr/local/sbin/pfSctl -c "interface newip $interface"'
need "EXPIRE branch"             'EXPIRE|FAIL|RELEASE)'
need "BOUND branch"              'BOUND|RENEW|REBIND|REBOOT)'
need "PREINIT branch"            'PREINIT)'
need "TIMEOUT branch"            'TIMEOUT)'
need "router state file"         'echo "$new_routers" > "/tmp/${interface}_router"'
need "ip state file"             'echo "$new_ip_address" > "/var/db/${interface}_ip"'
need "defaultgw gate"            '/tmp/${interface}_defaultgw'
need "delete_old_routes"         'delete_old_routes'
need "BOUND always notifies"     '[ "$reason" = BOUND ]'
need "old_ip_address test"       '[ -n "$old_ip_address" ]'

n1=$(/usr/bin/grep -n -F -e '. /etc/dhclient-enter-hooks' "$S" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
n2=$(/usr/bin/grep -n -F -e 'case $reason in' "$S" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
if [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ]; then
	ok "hook is sourced before case \$reason (lines $n1 < $n2)"
else
	bad "hook ordering (hook line='$n1' case line='$n2')"
fi

echo "== utilities used by the shim =="
for u in /usr/bin/timeout /usr/bin/env /usr/sbin/daemon /usr/bin/mktemp /usr/bin/stat \
         /usr/bin/logger /usr/bin/awk /usr/bin/tr /usr/bin/grep /usr/bin/head /usr/bin/cut \
         /usr/bin/tail /sbin/route /sbin/ifconfig /bin/ps /bin/kill /bin/sleep /bin/date \
         /bin/mkdir /bin/mv /bin/rm /bin/chmod /sbin/sha256 /bin/pkill; do
	if [ -x "$u" ]; then ok "$u"; else bad "$u missing"; fi
done

echo "== behaviour tests =="
r=$(/bin/sh -c 'h=0xff000000; echo $(( (h >> 24) & 255 )).$(( (h >> 16) & 255 ))' 2>/dev/null)
[ "$r" = "255.0" ] && ok "sh hex arithmetic" || bad "sh hex arithmetic (got '$r')"
/usr/bin/env -u HOME BELL_T=1 /usr/bin/true && ok "env -u / assignment" || bad "env -u"
/usr/bin/timeout 2 /usr/bin/true && ok "timeout" || bad "timeout"
/usr/sbin/daemon -f /usr/bin/true && ok "daemon -f" || bad "daemon -f"
x=$(printf '0xff000000' | /usr/bin/tr -cd 'A-Za-z0-9._:, -') && [ "$x" = "0xff000000" ] && ok "tr -cd" || bad "tr -cd"
h=$(sha256 -q "$S" 2>/dev/null); [ -n "$h" ] && ok "sha256 -q" || bad "sha256 -q"

echo "== filesystems (a RAM disk would drop /var/db/bell-admz at reboot) =="
/bin/df /var/db /var/run /tmp 2>&1

echo "== result =="
if [ "$FAIL" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; fi
echo "$FAIL CHECK(S) FAILED - do not install; send the output for review"
exit 1