<!--
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
-->
# Test and Verification

## Dry-run diagnostic

```text
mkdir -p /root/bell-admz   # place the shim, install.sh, uninstall.sh here; chmod 755
/usr/local/libexec/bell-admz-shim.sh diag 2>/dev/null || sh /root/bell-admz/bell-admz-shim.sh diag
sh /root/bell-admz/install.sh -n --i-have-console   # prints actions only
```

## Test plan

1. Confirm console access (iLO, since this is a DL360 G6, or VGA) and a config.xml backup (Diagnostics → Backup & Restore).

1. Run Phase 0 (the lease file and tcpdump). Try the option-modifier route first if the capture supports it.

1. Run install.sh --i-have-console. The mode is dryrun. Watch three or more 5-minute cycles. Expect DRYRUN EXPIRE: would defer followed by DRYRUN BOUND: would SKIP. Native behaviour is unchanged in this phase.

1. If a would SKIP line never appears, assumptions A1–A3 are wrong. Stop and inspect the log.

1. Switch to enforcement: echo enforce > /var/db/bell-admz/mode. Watch at least 12 cycles (one hour) with no rc.newwanip, no Reloading filter, and no gif0 flap.

1. Failure injection: run route delete default or ifconfig ix0 delete <ip> just before an EXPIRE. It must take the normal path (route state unavailable -> normal path).

1. Real-change simulation: disconnect the Giga Hub for more than 60 s, or change its DMZ host to a different MAC. Confirm native recovery runs, with the watchdog teardown logged.

1. Reboot. The first cycle must log no previous state and take the normal path.

## Validation checklist

- [ ] The log shows BOUND: effective WAN state UNCHANGED and no rc.newwanip starting ix0 on identical renewals.

- [ ] dpinger, unbound, and named elapsed time keeps growing across cycles.

- [ ] A forced change produces teardown: followed by a normal rc.newwanip.

- [ ] touch /var/db/bell-admz/DISABLE restores stock behaviour on the next event.

- [ ] DNS queries from a client against the Unbound VIP never fail during a cycle.

## Verification commands

```text
ifconfig ix0 inet                                     # WAN address and mask (hex)
route -n get default                                  # default gateway
route -n get 192.168.2.1                              # route to the DHCP server
GW=$(route -n get default | awk '/gateway:/{print $2}'); route -n get "$GW"   # Bell next hop
ps -axo pid,etime,command | grep '[d]pinger'          # dpinger stability
ps -axo pid,etime,command | grep '[u]nbound'          # Unbound stability
ps -axo pid,etime,command | grep '[n]amed'            # BIND stability
ifconfig gif0 | egrep 'inet6|tunnel|status'           # HE tunnel state
grep -c 'Reloading filter' /var/log/system.log        # compare before and after a cycle
swanctl --list-sas | head -20                         # IPsec
vtysh -c 'show bgp summary'                           # FRR/BGP
wg show                                               # WireGuard
dig @10.9.88.1 example.com +time=2 +tries=1           # DNS check; use your Unbound VIP
```

### Log monitor for a full lease cycle (about 330 s)

```text
timeout 330 tail -F /var/log/system.log /var/log/gateways.log 2>/dev/null | \
  egrep --line-buffered 'dhclient|bell-admz|rc\.newwanip|dpinger|check_reload_status|gif0|Reloading filter|unbound|named'
Recovery, limitations, confidence
```

## Rollback if the WAN becomes unreachable (from the iLO or VGA console)

```text
touch /var/db/bell-admz/DISABLE                        # immediate, no reboot
/usr/local/libexec/bell-admz-shim.sh flush
sh /root/bell-admz/uninstall.sh
/usr/local/sbin/dhclient -r ix0; killall dhclient 2>/dev/null
php -r "require_once('interfaces.inc'); interface_configure('wan', true);"   # or console menu option 2/11
# last resort: restore from /root/bell-admz-backup-*/ and `sha256 -c SHA256SUMS`; reboot only if needed
```

## Known limitations

- Assumptions A1–A6 are unverified against the actual 2.8.1 files.
- The shim holds a stale address for up to DEFER_MAX seconds if Bell really drops the lease. Recovery is delayed by that long, but it is not disabled.
- If the hub's lease expires and your address is actually revoked, the shim does nothing to prevent that outage.
- It handles IPv4 on ix0 only. IPv6 on the WAN, DHCPv6, and rc.newwanipv6 are untouched.
- daemon(8) watchdog behaviour inside the dhclient-script process group is assumed.
- If dpinger is not found for the WAN IP, the shim cannot verify the monitor route and always takes the normal path.
- The shim reduces the symptom. If the Hub rejects unicast renewals, the underlying lease churn continues, and every cycle still generates a DHCPDISCOVER.
- If Phase 0 shows no safe hook behaviour in 2.8.1, I recommend putting the Giga Hub in bridge or PPPoE-passthrough mode, or using a reviewed dhclient configuration change. I would not invent a different shim.

