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

# Enable ARP refresh service (keeps hostnames visible in LuCI connected clients)
/etc/init.d/arp-refresh enable
/etc/init.d/arp-refresh start

exit 0
