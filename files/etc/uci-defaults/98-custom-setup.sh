#!/bin/sh

# Enable and start the fan service
chmod +x /usr/libexec/rpcd/luci.fan
chmod +x /etc/init.d/fan
/etc/init.d/fan enable
/etc/init.d/fan start

chmod +x /usr/libexec/rpcd/luci.airoha_flowsense
chmod +x /etc/init.d/npu-jitter
chmod +x /usr/libexec/npu-jitter-daemon
/etc/init.d/npu-jitter enable
/etc/init.d/npu-jitter start
/etc/init.d/rpcd restart

# Remove default ULA prefix — prevents dual-address source selection issues on clients
# (devices picking fd::/8 ULA as source for global IPv6 destinations, causing silent drops)
uci -q delete network.globals.ula_prefix
uci commit network

uci set firewall.@defaults[0].flow_offloading=1
uci set firewall.@defaults[0].flow_offloading_hw=1
uci commit firewall
/etc/init.d/firewall restart

# Mark config as compatible with current schema (suppresses sysupgrade compat warning)
uci set system.@system[0].compat_version="2.0"
uci commit system

# odhcpd RFC 9096: OpenWrt's own /etc/uci-defaults/15_odhcpd points piodir at
# /tmp (tmpfs), so the stale-prefix state is destroyed by the reboot it exists
# to survive — the router forgets what prefix it advertised and can't deprecate
# it after a renumber. Point it at persistent storage instead; odhcpd creates
# the dir itself and only writes on an actual prefix change. No-op in AP mode
# (needs ra=server + a delegated prefix). Runs after 15_odhcpd, so this wins.
# Validated on hardware 2026-07-17. REMOVE once upstream fixes the default.
if [ -n "$(uci -q get dhcp.odhcpd)" ]; then
	uci set dhcp.odhcpd.piodir=/etc/odhcpd-piodir
	uci commit dhcp
fi

# Enable ARP refresh service (keeps hostnames visible in LuCI connected clients)
/etc/init.d/arp-refresh enable
/etc/init.d/arp-refresh start

exit 0
