#!/bin/sh
# bell-admz-monitor.sh - watch one full lease cycle (default 660 s).
# usage: bell-admz-monitor.sh [seconds] [-p]
#   -p  also capture DHCP and ICMP on ix0 to /root/bell-admz/cycle-<time>.pcap
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
SECS=660
PCAP=0
for a in "$@"; do
	case "$a" in
	-p) PCAP=1 ;;
	*[!0-9]*|'') echo "usage: $0 [seconds] [-p]" >&2; exit 2 ;;
	*) SECS=$a ;;
	esac
done

if [ "$PCAP" = 1 ]; then
	F="/root/bell-admz/cycle-$(date +%Y%m%d-%H%M%S).pcap"
	/usr/bin/timeout "$SECS" /usr/sbin/tcpdump -ni ix0 -s0 -w "$F" 'icmp or (udp and (port 67 or port 68))' >/dev/null 2>&1 &
	echo "capturing to $F"
fi

echo "watching for $SECS s; Ctrl-C to stop"
/usr/bin/timeout "$SECS" /usr/bin/tail -F \
  /var/log/bell-admz.log /var/log/dhcpd.log /var/log/system.log /var/log/gateways.log 2>/dev/null \
  | /usr/bin/grep --line-buffered -E 'bell-admz|DHCP Client|dhclient|rc\.newwanip|dpinger|check_reload_status|Reloading filter|gif0|unbound|named'
wait
echo "done; counts above should show no rc.newwanip, dpinger restart, filter reload, or gif0 flap after enforcement"