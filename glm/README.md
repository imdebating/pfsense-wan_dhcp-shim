# bell-admz-shield

A DHCP continuity hook for **pfSense CE 2.8.1** behind a **Bell Giga Hub
Advanced DMZ** handoff. Prevents unnecessary WAN teardown and firewall
service churn when Bell re-issues an identical lease.

## Problem

The Giga Hub's Advanced DMZ hands pfSense a **600-second DHCP lease** and
**never answers renewal requests** - neither the unicast T1 renewal at
T+300 s nor the broadcast rebind attempts near T2. The lease therefore
expires every 10 minutes and dhclient re-acquires it through full
discovery. Packet capture (2026-10-09) confirms the hub re-offers a
byte-identical lease every cycle: same IP, mask, gateway, server
identifier, and DNS.

Each expiry runs the full stock pfSense teardown path:

1. `pfSense-dhclient-script` deletes the WAN address and routes (EXPIRE).
2. Full DORA re-acquisition (~300 ms).
3. `pfSctl -c "interface newip ix0"` notifies `check_reload_status`.
4. `rc.newwanip` reconfigures the interface: dpinger is killed and
   restarted (including `sendto error: 65` while the address is absent),
   the filter ruleset reloads, the HE IPv6 tunnel (`gif0`) bounces twice,
   Unbound and package restart hooks may fire.

Net effect: roughly 0.7 s of hard outage plus ~9 s of reconfiguration,
every 10 minutes, indefinitely - with no change in effective WAN state.

## Root cause

Bell-side. The hub ignores DHCP renewals and requires periodic full
DORA exchanges to keep ADMZ forwarding active. This cannot be fixed on
the client; it can only be made harmless.

## Approach: retain-and-refresh

The stock `/usr/local/sbin/pfSense-dhclient-script` sources
`/etc/dhclient-enter-hooks` **before** acting on any `reason`, and aborts
the event if the hook sets the `exit_status` shell variable to nonzero
(the hook's own return value is ignored - verified against the installed
2.8.1 script). That is the earliest safe interception point: before any
address or route deletion, and before the `interface newip` notification.

The hook implements three decisions, all scoped to the configured WAN
interface (ix0):

- **EXPIRE** - if the recorded lease state matches what is still live on
  the interface (address, mask, default route via the recorded gateway),
  set `exit_status=2` and keep the address and routes in place.
- **PREINIT** - skip the interface reset and `/tmp/<iface>_router` rename
  while the recorded address is still live.
- **BOUND / RENEW / REBIND / REBOOT** - compare the new lease (IP, mask,
  broadcast, gateway, DHCP server identifier, DNS servers, classless
  routes) against the recorded state and the live interface, and suppress
  the rebuild and the `interface newip` notification **only on an exact
  match**.

dhclient itself is untouched: it still performs the full DORA exchange
Bell requires, and the lease database updates normally.

## Fail-open design

Every uncertain condition takes the normal stock pfSense path:

- No previous state (first event after install or reboot)
- Any lease field changed - a real Bell IP, gateway, mask, DNS, or server
  change runs stock logic unchanged, then state is re-learned
- Recorded address not live on the interface
- Default-route, DHCP-server-route, or monitor-route mismatch
- Lock contention, malformed lease data, unknown mode

Manual release/renew, genuine outages (`FAIL`, `TIMEOUT`), link events,
and gateway alarms are never intercepted. No IPs, gateways, masks, or
servers are hard-coded anywhere. The shim never edits generated pfSense
configuration, never disables gateway monitoring, and never invokes
`dhclient-script`, `dhclient`, or `pfSctl` (recursion is impossible).

## Files

| Path | Purpose |
| --- | --- |
| `/conf/bell-admz-shield/dhclient-enter-hooks` | The hook (sourced, never executed) |
| `/conf/bell-admz-shield/bell-admz-boot.sh` | Source of the boot/upgrade restore script |
| `/conf/bell-admz-shield/bell-admz-diag.sh` | Offline decision simulation and log tail |
| `/conf/bell-admz-shield/config` | Interface, mode (dryrun/retain), monitor IPs |
| `/usr/local/etc/rc.d/bell-admz.sh` | Restores the hook link after boot/upgrade |
| `/etc/dhclient-enter-hooks` | Symlink into the stock script's hook seam |
| `/var/run/bell-admz/state` | Learned lease record (volatile; fail-open at boot) |
| install-bell-admz.sh | Install script |
| uninstall-bell-admz.sh | Uninstall script |
| README.md | This readme file |

Runtime state deliberately lives on the volatile `/var` filesystem so the
first event after any reboot takes the normal path and re-learns.
Persistent artifacts live in `/conf`, which survives pfSense upgrades.

## Install

```sh
./install-bell-admz.sh -i ix0 -s "1.1.1.1"     # -s: dpinger monitor IP(s)
```

Installs in **dryrun** mode by default: every decision is logged but the
stock behaviour is unchanged. Observe at least one full 600 s cycle:

```sh
/usr/local/sbin/clog /var/log/system.log | grep 'bell-admz' | tail
/conf/bell-admz-shield/bell-admz-diag.sh          # -n for negative control
```

Switch to retain (with console or out-of-band access available):

```sh
printf 'BELL_ADMZ_IFACE=ix0\nBELL_ADMZ_MODE=retain\nBELL_ADMZ_ENABLED=1\nBELL_ADMZ_MONITORS=1.1.1.1\n' \
  > /conf/bell-admz-shield/config.new && mv /conf/bell-admz-shield/config.new /conf/bell-admz-shield/config
```

Success signature, once per 600 s: `EXPIRE: retaining ...`,
`PREINIT: skipping ...`, `BOUND: unchanged lease ... suppressing rebuild`,
with **no** `rc.newwanip`, dpinger restart, `Reloading filter`, or `gif0`
link events in the window. dpinger, Unbound, and named PIDs stay stable.

## Disable / rollback

```sh
rm -f /etc/dhclient-enter-hooks    # instant disable, no reboot
./uninstall-bell-admz.sh           # full removal
```

If the WAN becomes unreachable, do the `rm` from the console, then force
one stock cycle with Status > Interfaces > Renew. Reference backups of
the pfSense originals are kept under `/root/bell-admz-backup-*`.

## Upgrades

A pfSense upgrade replaces `pfSense-dhclient-script`. The boot script only
restores the hook link if the upgraded script still supports the
enter-hook seam with abort-on-`exit_status` semantics; otherwise it logs
and leaves stock behaviour in place. After any upgrade: re-run the
installer's verification greps, reinstall in dryrun, and observe a clean
cycle before re-enabling retain.

## Limitations

- Only neutralizes the ix0 DHCP-cycle trigger; `rc.newwanip` from other
  causes (package reloads, manual apply, real WAN changes) is untouched.
- Does not make Bell answer renewals, and does not mask a genuine outage.
- Absorbed BOUND events also skip rewriting the lease-derived resolv
  bookkeeping - harmless while the lease is unchanged, and any change
  runs the stock path.
- Every `dhclient` instance on the box sources the hook; the interface
  gate keeps it inert for non-WAN interfaces.

## Status

Design verified against the installed 2.8.1 `pfSense-dhclient-script`
source, the published `rc.newwanip` logic, and an on-wire packet capture
of multiple lease cycles. Confidence: 94%. Experimental - use at your
own risk, and always retain console or out-of-band recovery access when
running in retain mode.
