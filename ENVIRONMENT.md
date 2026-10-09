Target: pfSense 2.9.0-RELEASE
Platform: FreeBSD-based pfSense
WAN interface: ix0
Bell Giga Hub Advanced DMZ
DHCP lease: 600 seconds
Symptom: ADMZ lease time is 600 seconds, but it ignores all renew requests. The address expires and pfSense must process the address as new causing a brief outage.
Outcome: No noticeable outage to end users