# Reaching the dish in bypass mode

In bypass mode the Starlink router stops routing and your own router takes over
([Starlink: What is bypass mode?](https://starlink.com/support/article/a0fe8d51-32f7-d2b9-d74a-801e31ad9f6a)).
The dish still answers at `192.168.100.1`, but that address sits on the far side of your router's
WAN port. Your router has to send traffic for it out of the Starlink WAN, not to its default
gateway somewhere else.

StarPulse shows the dish data again once this works. Devices, mesh nodes, pause, rules and the
router speed test need the Starlink router, so they stay empty in bypass mode.

> [!NOTE]
> The maintainer's kit is not in bypass mode, so these steps come from each router's
> documentation and its community, linked below, and were not tested here. If a step is wrong for
> your firmware, please open an issue.

## Check first

From a Mac behind your router:

```bash
route -n get 192.168.100.1      # which interface the Mac uses
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.100.1:9201/   # any number means the dish answered
```

If `curl` prints `000`, the dish is not reachable yet. StarPulse also shows the likely cause when the
dish does not answer.

## Two ways to do it

1. **A host route**: `192.168.100.1/32` out of the Starlink WAN interface.
2. **An extra address on the WAN**: give the WAN interface a second address in
   `192.168.100.0/24` (for example `192.168.100.2/24`), so the dish is on a directly connected
   network. Firewalls such as pfSense and OPNsense also need an outbound NAT rule for it.

Use one, not both.

## OpenWrt

A route section without `netmask` is a host route
([OpenWrt: Static routes](https://openwrt.org/docs/guide-user/network/routing/routes_configuration)).
Replace `wan` with the name of your Starlink interface:

```sh
uci add network route
uci set network.@route[-1].interface='wan'
uci set network.@route[-1].target='192.168.100.1'
uci commit network
/etc/init.d/network reload
```

In LuCI the same setting is under Network › Routing › Static IPv4 Routes.

## MikroTik RouterOS

Members of the MikroTik forum reach the dish in bypass mode by adding an address in the dish's
subnet to the interface facing Starlink
([forum thread](https://forum.mikrotik.com/t/starlink-and-static-routes/164195)). Replace
`ether1` with that interface:

```
/ip address add address=192.168.100.100/24 interface=ether1
```

Check that no firewall rule drops traffic from your LAN to `192.168.100.1`. Route syntax, if you
prefer a route: [MikroTik: IP Routing](https://help.mikrotik.com/docs/spaces/ROS/pages/328084/IP+Routing).

## pfSense

Follow Netgate's recipe
[Accessing a CPE/Modem from Inside the Firewall](https://docs.netgate.com/pfsense/en/latest/recipes/modem-access.html)
with the dish's subnet:

1. Assign a new interface on the same physical port as the Starlink WAN, with a static IPv4 address
   such as `192.168.100.2/24` and **no** upstream gateway.
2. Firewall › NAT › Outbound: switch to Hybrid Outbound NAT and add a rule on that interface, with
   your LAN subnet as source, `192.168.100.0/24` as destination and Interface Address as
   translation.

**Dual-WAN:** if your LAN rules send traffic to a gateway group, add a pass rule for destination
`192.168.100.1` **above** them, with no gateway set; rules with a gateway override the routing
table ([Netgate: Bypassing Policy Routing](https://docs.netgate.com/pfsense/en/latest/multiwan/policy-route.html#bypassing-policy-routing)).

## OPNsense

1. Interfaces › Virtual IPs › Settings: add an IP Alias `192.168.100.2/24` on the Starlink WAN
   ([OPNsense: Virtual IPs](https://docs.opnsense.org/manual/firewall_vip.html)).
2. Firewall › NAT › Outbound: add a manual rule on the WAN, source your LAN network, destination
   `192.168.100.1`, translation `192.168.100.2`.

This follows a tutorial on the OPNsense forum
([Bridge Modem access using VIPs](https://forum.opnsense.org/index.php?topic=36936.0)). Replies
there report that it can also need "Block private networks" turned off on that WAN. With dual-WAN,
the same rule ordering as on pfSense applies.

## Other routers

Look in the router's manual for **static routes** and add destination `192.168.100.1`, mask
`255.255.255.255`, interface set to the Starlink WAN. If the router only accepts a gateway address,
the extra-address method above is not available, and the route may not work; this depends on the
router.
