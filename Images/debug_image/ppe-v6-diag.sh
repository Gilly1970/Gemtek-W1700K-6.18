#!/bin/sh
# ppe-v6-diag.sh - diagnose IPv6 routed flows blackholing under Airoha PPE HW offload

WATCH="${1:-5}"
DBG=/sys/kernel/debug
BIND="$DBG/ppe/bind"
N=/tmp/ppe_neigh.$$
S1=/tmp/ppe_snap1.$$
S2=/tmp/ppe_snap2.$$
D1=/tmp/ppe_dev1.$$
D2=/tmp/ppe_dev2.$$
trap 'rm -f "$N" "$S1" "$S2" "$D1" "$D2"' EXIT

# --- debugfs must be mounted to read the FOE table ---
if [ ! -e "$BIND" ]; then
	mount -t debugfs none "$DBG" 2>/dev/null
fi
if [ ! -e "$BIND" ]; then
	echo "ERROR: $BIND not found. Is this the airoha PPE build with debugfs enabled?"
	exit 1
fi

echo "=================================================================="
echo " Airoha PPE IPv6 offload diagnostics   ($(date))"
echo "=================================================================="

echo
echo "### Offload switches (nftables flowtable + sysctls) #############"
nft list ruleset 2>/dev/null | grep -iE "flowtable|flow add|nfproto|hw" | sed 's/^/  /'
echo "  net.netfilter.nf_flowtable_* :"
sysctl -a 2>/dev/null | grep -iE "nf_flowtable|flow_offload" | sed 's/^/    /'

echo
echo "### IPv6 WAN reachability (routing sanity - check this FIRST) ###"
echo "  -- default route(s)  (OpenWrt PD installs 'default from <prefix>' source-specific routes):"
DEF="$(ip -6 route show default 2>/dev/null; ip -6 route show table all 2>/dev/null | grep -E '^default')"
DEF="$(echo "$DEF" | sort -u | grep .)"
if [ -n "$DEF" ]; then
	echo "$DEF" | sed 's/^/    /'
else
	echo "    !! NO IPv6 default route installed - the router itself cannot reach the v6"
	echo "    !! internet. Every v6 flow will stall regardless of PPE. Fix WAN6 RA/DHCPv6-PD"
	echo "    !! before blaming offload."
fi
# pick a local GLOBAL source so route-get matches the source-specific 'default from' route.
# (a bare 'ip -6 route get' with no source can wrongly say 'Network unreachable' on PD setups)
GSRC="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | grep -vi '^fe80' | cut -d/ -f1 | head -1)"
echo "  -- can the router route to the v6 internet? (route get 2606:4700:4700::1111${GSRC:+ from $GSRC}):"
ip -6 route get 2606:4700:4700::1111 ${GSRC:+from "$GSRC"} 2>&1 | head -1 | sed 's/^/    /'
[ -z "$GSRC" ] && echo "    (no local global v6 source found - result may be a false 'unreachable')"

# --- derive WAN dev + gateway from the default route, then health-check them ---
WANDEV="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
GW6="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"
echo "  -- WAN device / v6 gateway: ${WANDEV:-<unknown>} / ${GW6:-<none>}"
if [ -n "$WANDEV" ]; then
	echo "  -- WAN global address(es) (need >=1, else no PD / RA):"
	ip -6 addr show dev "$WANDEV" scope global 2>/dev/null | awk '/inet6/{print "    "$2}'
	[ -z "$(ip -6 addr show dev "$WANDEV" scope global 2>/dev/null | grep inet6)" ] && echo "    (none)"
fi
if [ -n "$GW6" ]; then
	echo "  -- v6 gateway neighbour state (want REACHABLE/STALE/DELAY, NOT FAILED/INCOMPLETE):"
	ip -6 neigh show "$GW6" 2>/dev/null | sed 's/^/    /'
	[ -z "$(ip -6 neigh show "$GW6" 2>/dev/null)" ] && echo "    !! gateway $GW6 not in neigh table"
fi

echo
echo "### Forwarding / firewall / MTU sanity  (his-setup vs bug) ######"
echo "  net.ipv6.conf.all.forwarding = $(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null) (must be 1)"
for d in "$WANDEV" br-lan; do
	[ -n "$d" ] && [ -e "/sys/class/net/$d/mtu" ] && echo "  MTU $d = $(cat /sys/class/net/$d/mtu)"
done
echo "  -- fw4 v6 forward/drop counters (a climbing drop here = firewall, not PPE):"
nft list chain inet fw4 forward 2>/dev/null | grep -iE "policy|drop|reject" | sed 's/^/    /'
echo "  -- IPv6 conntrack + offload flag ([OFFLOAD]/[HW_OFFLOAD] = handed to PPE):"
grep -iE "ipv6" /proc/net/nf_conntrack 2>/dev/null | grep -iE "OFFLOAD|tcp|udp|icmpv6" | head -15 | sed 's/^/    /'
[ ! -s /proc/net/nf_conntrack ] && echo "    (nf_conntrack not readable)"

echo
echo "### WAN6 / RA / DHCPv6-PD log tail  (upstream-provisioning health) ##"
echo "  -- recent odhcp6c / RA / DHCPv6 / prefix events (last 20):"
LOG6="$(logread 2>/dev/null | grep -iE "odhcp6c|dhcpv6|router advert|prefix|IA_PD|solicit|renew|rebind" | tail -20)"
if [ -n "$LOG6" ]; then
	echo "$LOG6" | sed 's/^/    /'
else
	echo "    (nothing in log buffer - may have rotated; not necessarily a fault)"
fi
echo "  -- v6-related errors/warnings in log (last 15):"
LOGERR="$(logread 2>/dev/null | grep -iE "ipv6|dhcpv6|odhcp|netifd" | grep -iE "err|fail|unreach|no route|timeout|expire|reject|drop" | tail -15)"
[ -n "$LOGERR" ] && echo "$LOGERR" | sed 's/^/    /' || echo "    (none)"

echo
echo "### Delegated-prefix routing (the /60 tell-tale) ################"
echo "  -- unreachable aggregate route(s) (present for /60+, absent for a bare /64):"
ip -6 route show table all 2>/dev/null | grep -i unreachable | sed 's/^/    /'
[ -z "$(ip -6 route show table all 2>/dev/null | grep -i unreachable)" ] && echo "    (none)"
echo "  -- on-link LAN prefixes:"
ip -6 route show 2>/dev/null | grep -vE "unreachable|default|fe80|via" | grep dev | sed 's/^/    /'

# --- capture two FOE + interface-counter snapshots + the neighbour table ---
ip -6 neigh show > "$N" 2>/dev/null
cat /proc/net/dev > "$D1" 2>/dev/null
cat "$BIND" > "$S1" 2>/dev/null
sleep "$WATCH"
cat "$BIND" > "$S2" 2>/dev/null
cat /proc/net/dev > "$D2" 2>/dev/null

echo
echo "### Hardware-bound IPv6 flows  (window = ${WATCH}s) #############"
echo "  legend: PKT_DELTA = per-entry packet delta over the window."
echo "  !! UNRELIABLE on AN7581 (2026-07-08): the counter is fed from NPU per-entry"
echo "  !! stats which this firmware does NOT populate -> it reads 0 even for flows"
echo "  !! that ARE forwarding fine (verified: working IPv4 entries also show 0)."
echo "  !! DO NOT treat PKT_DELTA=0 as a black-hole. Judge by: (a) did the transfer"
echo "  !! actually STALL, (b) the interface RX-vs-TX table below, (c) DBG path lines."
echo

awk -v win="$WATCH" '
	# ---- ip -6 neigh : build mac -> "ip dev state" ----
	FILENAME ~ /ppe_neigh/ {
		ip=$1; dev=""; mac=""; state=$NF
		for (k=1;k<=NF;k++){
			if ($k=="dev")    dev=$(k+1)
			if ($k=="lladdr") mac=tolower($(k+1))
		}
		if (mac!="") nb[mac]=ip" dev "dev" "state
		next
	}
	# ---- a FOE bind line, parse the tokens we care about ----
	function parse(line,   k,n,orig,eth,pk,arr,dst,dmac,a,ipp,i,ipx){
		orig=""; eth=""; pk=""
		n=split(line,arr," ")
		for(k=1;k<=n;k++){
			if (arr[k] ~ /^orig=/)    orig=substr(arr[k],6)
			else if (arr[k] ~ /^eth=/) eth=substr(arr[k],5)
			else if (arr[k] ~ /^packets=/) pk=substr(arr[k],9)
		}
		id=arr[1]
		# dst ip = right side of orig "src->dst", strip trailing :port
		split(orig,a,"->"); dst=a[2]
		split(dst,ipp,":")
		ipx=ipp[1]; for(i=2;i<=8;i++) ipx=ipx":"ipp[i]   # 8 hextets, drop :port
		DST[id]=ipx
		# next-hop mac = right side of eth "hsrc->hdst"
		split(eth,a,"->"); dmac=tolower(a[2]); MAC[id]=dmac
		return pk
	}
	FILENAME ~ /ppe_snap1/ { if ($0 ~ /IPv6 /){ P1[$1]=parse($0) } next }
	FILENAME ~ /ppe_snap2/ { if ($0 ~ /IPv6 /){ P2[$1]=parse($0) } }
	END {
		printf "  %-6s %-40s %-17s %-9s %s\n", "ID","DST_IP","NEXTHOP_MAC","PKT_DLT","NEIGHBOUR / VERDICT"
		printf "  %-6s %-40s %-17s %-9s %s\n", "------","----------------------------------------","-----------------","---------","-------------------"
		any=0
		for (id in P2){
			any=1
			d = P2[id]-P1[id]; if (d<0) d=0
			mac=MAC[id]
			if (mac in nb)              verdict=nb[mac]
			else if (mac ~ /^00:00:00/) verdict="!! NULL/UNRESOLVED next-hop MAC"
			else                        verdict="!! MAC not a known IPv6 neighbour (stale/wrong next-hop?)"
			flag=""
			if (d>0 && verdict ~ /^!!/) flag="   <== HW forwarding to bad next-hop = BLACK HOLE"
			printf "  %-6s %-40s %-17s %-9s %s%s\n", id, DST[id], mac, d, verdict, flag
		}
		if (!any) print "  (no IPv6 flows are hardware-bound right now - is a v6 transfer running?)"
	}
' "$N" "$S1" "$S2"

echo
echo "### Raw FOE entry bytes  (what the HW actually got programmed) ##"
echo "  For the VLAN black-hole hunt: on the IPv6 upload entry (egress wan.<vid>),"
echo "  check eth=SMAC->DMAC (v6 uses an SMAC-ID table, not an inline MAC),"
echo "  etype (want 86dd), and vlan=<vid>,<vid2>.  Compare against a working IPv4"
echo "  line: if the v6 SMAC or vlan= differs from the v4 one, that's the smoking gun."
echo "  ib1 decode: VLAN_LAYER=bits19:16  VPM=bits21:20  (both = #vlan tags to push)"
echo
echo "  -- IPv6 bind entries (raw):"
grep -E 'IPv6 ' "$S2" 2>/dev/null | sed 's/^/    /'
[ -z "$(grep -E 'IPv6 ' "$S2" 2>/dev/null)" ] && echo "    (none bound)"
echo "  -- IPv4 bind entries (raw, working reference - up to 4):"
grep -E 'IPv4 ' "$S2" 2>/dev/null | head -4 | sed 's/^/    /'
[ -z "$(grep -E 'IPv4 ' "$S2" 2>/dev/null)" ] && echo "    (none bound)"
# decode VLAN_LAYER / VPM from ib1 (busybox awk has no strtonum: slice hex nibbles).
# ib1 is printed as %08x -> 8 hex chars. char4=bits19:16 (VLAN_LAYER), char3=bits23:20 (VPM=low 2 bits)
awk '
	function hex1(c){ c=tolower(c); if (c ~ /^[0-9]$/) return c+0; return index("abcdef",c)+9 }
	/IPv6 / {
		ib1=""
		for (k=1;k<=NF;k++) if ($k ~ /^ib1=/) ib1=substr($k,5)
		if (length(ib1)!=8) next
		vlan_layer=hex1(substr(ib1,4,1))     # bits 19..16
		vpm=hex1(substr(ib1,3,1))%4          # bits 21..20
		printf "    ib1[%s]=%s -> VLAN_LAYER=%d VPM=%d (both should = #tags pushed on egress)\n", $1, ib1, vlan_layer, vpm
	}
' "$S2" 2>/dev/null

echo
echo "### Traffic flow over the window  (where does it stop?) ########"
echo "  RX = packets the iface received, TX = packets it sent, DROP = dropped."
echo "  Download stalling: WAN RX climbs but LAN TX flat = forwarding black-hole."
# parse /proc/net/dev by splitting on ':' first so the iface name is field-independent
awk '
	{ line=$0; sub(/^[ \t]+/,"",line); ci=index(line,":");
	  name=substr(line,1,ci-1); rest=substr(line,ci+1);
	  nf=split(rest,c," ");
	  # c[1]=rxbytes c[2]=rxpkts c[4]=rxdrop  c[9]=txbytes c[10]=txpkts c[12]=txdrop
	  if (FILENAME ~ /ppe_dev1/){ RXP1[name]=c[2]; RXD1[name]=c[4]; TXP1[name]=c[10]; TXD1[name]=c[12] }
	  else { RXP2[name]=c[2]; RXD2[name]=c[4]; TXP2[name]=c[10]; TXD2[name]=c[12] }
	}
	END{
		printf "  %-12s %12s %12s %10s %10s\n","IFACE","RX_pkts","TX_pkts","RX_drop","TX_drop"
		for (n in RXP2){
			rx=RXP2[n]-RXP1[n]; tx=TXP2[n]-TXP1[n]; rd=RXD2[n]-RXD1[n]; td=TXD2[n]-TXD1[n]
			# only show ifaces that moved something or dropped something
			if (n=="lo") continue
			if (rx==0 && tx==0 && rd==0 && td==0) continue
			printf "  %-12s %12d %12d %10d %10d\n", n, rx, tx, rd, td
		}
	}
' "$D1" "$D2"
echo "  (all-zero table = no traffic in window; re-run during an active v6 download)"

echo
echo "### Kernel route decision for each bound IPv6 dst ###############"
echo "  (download flows: dst = a LAN client; watch for 'unreachable' or wrong dev)"
for ip in $(awk '/IPv6 /{for(k=1;k<=NF;k++) if($k ~ /^orig=/){split(substr($k,6),a,"->"); split(a[2],p,":"); print p[1]":"p[2]":"p[3]":"p[4]":"p[5]":"p[6]":"p[7]":"p[8]}}' "$S2" | sort -u); do
	printf "  %-40s -> " "$ip"
	ip -6 route get "$ip" ${GSRC:+from "$GSRC"} 2>&1 | head -1
done

echo
echo "=================================================================="
echo " Decision tree:  IS IT HIS SETUP, OR AN ACTUAL PPE HW BUG?"
echo "=================================================================="
echo " Run this DURING an active IPv6 download from a stalling LAN client,"
echo " then read top-down - the first matching branch wins:"
echo
echo " [SETUP] No default route, or route-get says 'unreachable' even WITH a"
echo "         source -> WAN6 RA/DHCPv6-PD is broken. Not a PPE bug. Fix WAN6."
echo " [SETUP] v6 gateway neighbour FAILED/INCOMPLETE, or WAN has no global"
echo "         address -> upstream link/RA problem. Not a PPE bug."
echo " [SETUP] net.ipv6.conf.all.forwarding = 0, or fw4 forward 'drop' counter"
echo "         climbs -> forwarding/firewall config. Not a PPE bug."
echo " [SETUP] WAN MTU < 1500 or PMTU stalls only large transfers -> MTU/PMTUD."
echo
echo " [INCONCLUSIVE] Traffic table all-zero -> nothing was flowing; the client"
echo "         wasn't actually downloading. Re-run under real load."
echo
echo " NOTE (2026-07-08): IGNORE PKT_DLT here - it is unreliable on AN7581 (NPU"
echo " does not populate per-entry stats; reads 0 even for working flows). Use the"
echo " REAL signals below instead."
echo
echo " [HW BUG] The transfer actually STALLS (client gets ~nothing / times out)"
echo "          AND the interface table shows WAN RX_pkts CLIMBING while the"
echo "          client-facing TX (LAN/WiFi) stays ~FLAT -> packets enter, get"
echo "          handed to HW, and vanish = PPE black-hole. (This is the ground"
echo "          truth: a genuine stall + WAN-in >> client-out.)"
echo " [CONFIRM] Re-run with 'flow_offloading_hw=0' (or a 'meta nfproto ipv4'"
echo "          flowtable). If the SAME transfer now COMPLETES -> confirmed the"
echo "          PPE HW offload was black-holing it. That A/B is definitive."
echo " [OK]     Transfer COMPLETES (even if PKT_DLT reads 0) -> NOT black-holing;"
echo "          PKT_DLT=0 is just the dead NPU counter, not a fault."
echo "=================================================================="
