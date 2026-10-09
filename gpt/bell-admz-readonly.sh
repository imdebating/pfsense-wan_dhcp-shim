#!/bin/sh
# Read-only native-state collector. Root is required for complete visibility.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
LC_ALL=C
export LC_ALL
[ "$(/usr/bin/id -u)" = 0 ] || exit 77
section() { printf '\n===== %s =====\n' "$1"; }
section 'System identity'
/bin/date
/usr/bin/uname -a
/bin/cat /etc/version
section 'Raw process names: no executable-name filtering'
/bin/ps -axww -o pid,ppid,ucomm,lstart,etime
section 'DHCP and dpinger arguments, filtered on FreeBSD accounting name'
/bin/ps -axww -o pid=,ucomm=,args= | /usr/bin/awk '$2 == "dhclient" || $2 == "dpinger"'
section 'Network state'
/sbin/ifconfig ix0
/sbin/ifconfig gif0
/usr/bin/netstat -rn -f inet
/usr/bin/netstat -rn -f inet6
/sbin/route -n get -inet default
section 'Dynamic WAN cache'
gateway=
for file in /var/db/ix0_ip /tmp/ix0_router /tmp/ix0_router.last /tmp/ix0_defaultgw
do
    if [ -f "$file" ]; then printf '\n--- %s ---\n' "$file"; /bin/cat "$file"; printf '\n'; fi
done
if [ -f /tmp/ix0_router ]; then IFS= read -r gateway < /tmp/ix0_router || :; fi
if printf '%s\n' "$gateway" | /usr/bin/awk '
    BEGIN { ok=0 }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        n=split($0,a,"."); ok=(n==4)
        for(i=1;i<=n;i++) if(length(a[i])>3 || a[i]+0>255) ok=0
    }
    END { exit(ok ? 0 : 1) }
'; then /sbin/route -n get -inet "$gateway"; fi
section 'Diagnostic targets supplied in the latest evidence; no routes changed'
/sbin/route -n get -inet 192.168.2.1
/sbin/route -n get -inet 1.1.1.1
section 'Current native source and checksums; review before sharing custom content'
for file in /sbin/dhclient-script /usr/local/sbin/dhclient-script /usr/local/sbin/pfSense-dhclient-script /etc/rc.newwanip /etc/rc.linkup
do
    if [ -f "$file" ]; then
        printf '\n--- %s ---\n' "$file"
        /bin/ls -l "$file"
        /sbin/sha256 "$file"
        /bin/cat "$file"
    fi
done
section 'DHCP configuration: complete existing files'
for file in /etc/dhclient.conf /var/etc/dhclient*
do
    [ -f "$file" ] || continue
    printf '\n--- %s ---\n' "$file"
    /bin/cat "$file"
done
section 'Existing hooks'
for file in /etc/dhclient-enter-hooks /etc/dhclient-exit-hooks
do
    if [ -f "$file" ]; then printf '\n--- %s ---\n' "$file"; /bin/cat "$file"; else printf 'Absent: %s\n' "$file"; fi
done
section 'Recent DHCP and observer entries'
for file in /var/log/system.log /var/log/dhcpd.log
do
    [ -f "$file" ] || continue
    printf '\n--- %s ---\n' "$file"
    /usr/bin/grep -E 'dhclient|bell-admz-v2|EXPIRE|PREINIT|BOUND|RENEW|REBIND' "$file" | /usr/bin/tail -n 150
done
section 'Available package command locations'
for utility in timeout lockf swanctl vtysh wg
do
    command -v "$utility" || :
done
printf '\nRead-only collection complete; individual missing-state errors are not suppressed.\n'
exit 0
