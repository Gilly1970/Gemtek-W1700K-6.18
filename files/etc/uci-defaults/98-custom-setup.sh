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

uci -q delete network.globals.ula_prefix
uci commit network

uci set firewall.@defaults[0].flow_offloading=1
uci set firewall.@defaults[0].flow_offloading_hw=1
uci commit firewall
/etc/init.d/firewall restart

# Mark config as compatible with current schema (suppresses sysupgrade compat warning)
uci set system.@system[0].compat_version="2.0"
uci commit system

if [ -n "$(uci -q get dhcp.odhcpd)" ]; then
	uci set dhcp.odhcpd.piodir=/etc/odhcpd-piodir
	uci commit dhcp
fi

# Enable ARP refresh service (keeps hostnames visible in LuCI connected clients)
/etc/init.d/arp-refresh enable
/etc/init.d/arp-refresh start

chmod +x /usr/bin/npu-reboot-guard.sh
chmod +x /etc/init.d/npu-reboot-guard
/etc/init.d/npu-reboot-guard enable
/etc/init.d/npu-reboot-guard start

exit 0
