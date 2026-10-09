# Bell Advanced DMZ Continuity Shim for pfSense

A scoped, fail-open continuity hook that prevents WAN interface flaps, route teardown, and service restarts during Bell Giga Hub Advanced DMZ (ADMZ) DHCP lease cycles on pfSense.

---

## The Problem

When using Bell Canada's Giga Hub or Home Hub 4000 in Advanced DMZ mode:

1. **Short Lease Window:** The Bell Hub issues a 600-second (10-minute) DHCP lease to the pfSense WAN interface (`ix0`).
2. **Ignored Renewals:** The Hub ignores all RFC 2131 unicast `DHCPREQUEST` frames during the T1 renewal window (300 seconds), as well as broadcast `DHCPREQUEST` frames during the T2 rebind window (525 seconds).
3. **Destructive Expiration:** At 600 seconds, the lease reaches `EXPIRE`. Unmodified pfSense DHCP logic (`/usr/local/sbin/pfSense-dhclient-script`) immediately purges the WAN IP alias, flushes ARP entries, and removes the default route.
4. **Service Flapping Cascade:** 
   - A subsequent `DHCPDISCOVER` reacquires the exact same IP and gateway within 300 milliseconds.
   - However, during the brief route drop, gateway monitoring (`dpinger`) encounters `sendto error: 65` (`EHOSTUNREACH`) and exits on signal 15.
   - `rc.newwanip` is triggered unconditionally on `BOUND`, reloading the packet filter, tearing down and rebuilding `gif0` (Hurricane Electric IPv6 tunnel), and restarting packages (Unbound, BIND, pfBlockerNG, IPsec, FRR/BGP, WireGuard).
   - This causes network and DNS interruptions every 10 minutes.

---

## The Approach

Rather than forking the core pfSense scripts or hardcoding static routes, this fix leverages native enter-hook support in `pfSense-dhclient-script` (lines 216–224):

```sh
if [ -f /etc/dhclient-enter-hooks ]; then
    . /etc/dhclient-enter-hooks
    if [ $exit_status -ne 0 ]; then
        exit $exit_status
    fi
fi
```

By intercepting DHCP transitions inline at `/etc/dhclient-enter-hooks`, the shim enforces non-destructive behavior **only when the effective WAN state is unchanged**:

### 1. Intercept `EXPIRE` (Suppression)
When `reason=EXPIRE` fires on `ix0`, the shim inspects the live kernel state against the cached lease. If the active IP and default gateway are healthy and match the cache, the shim sets `exit_status=1`. This aborts `pfSense-dhclient-script` at line 223 before it can execute `delete_old_address` and `delete_old_routes`. The interface IP, default route, and ARP cache remain live in the kernel.

### 2. Intercept `PREINIT` (Interface Preservation)
When `reason=PREINIT` fires within 60 seconds of a suppressed `EXPIRE`, the shim sets `exit_status=1`. This prevents the script from deconfiguring the interface or rotating route markers. Because `dhclient` uses raw Berkeley Packet Filter (`/dev/bpf`) sockets, it broadcasts `DHCPDISCOVER` at Layer 2 without needing the IP removed.

### 3. Intercept `BOUND` (Multi-Field Evaluation)
When the Bell Hub responds with `DHCPACK`, the shim performs a multi-field comparison across:
- Offered IPv4 address vs. current kernel IP
- Offered subnet mask vs. current kernel mask
- Offered gateway router vs. current kernel default gateway
- DHCP server identifier (`192.168.2.1`)
- Kernel default route egress interface (`ix0`)

* **Identical State:** The shim refreshes tracking files (`/tmp/ix0_router`, `/var/db/ix0_ip`), updates the timestamp in `/var/run/bell_admz/state_ix0`, and executes `exit 0`. Sourcing `exit 0` immediately terminates the parent `pfSense-dhclient-script`, bypassing `notify_rc_newwanip`. Services, tunnels, and monitoring daemons continue uninterrupted.
* **State Change Detected (Fail-Open):** If any value changes (new IP, new gateway, different subnet, missing route) or if state is ambiguous, the shim updates the cache and returns cleanly without exiting. `pfSense-dhclient-script` proceeds normally, executing full reconfiguration and invoking `rc.newwanip` to rebuild tunnels and routing.

---

## File Structure

```text
/etc/dhclient-enter-hooks            # Sourced by pfSense-dhclient-script
/usr/local/bin/bell-admz-shim.sh    # Evaluation engine and lock manager
/var/run/bell_admz/                 # RAM-backed state directory (cleared on reboot)
/root/install-bell-shim.sh          # Backup and deployment script
/root/uninstall-bell-shim.sh        # Emergency console rollback script
```

---

## Installation and Verification

1. Run the installer:
   ```sh
   sh /root/install-bell-shim.sh
   ```

2. Monitor the log output across a 10-minute renewal cycle:
   ```sh
   tail -F -n 0 /var/log/system.log | grep --line-buffered -E 'dhclient|bell-admz-shim|rc\.newwanip|dpinger|gif0'
   ```

3. Confirm that:
   - `EXPIRE` and `PREINIT` are intercepted and suppressed.
   - `Unchanged WAN state confirmed` is logged on `BOUND`.
   - `sendto error: 65` does not recur in gateway logs.
   - `dpinger` process ID remains stable.
   - `gif0` remains continuously `UP`.