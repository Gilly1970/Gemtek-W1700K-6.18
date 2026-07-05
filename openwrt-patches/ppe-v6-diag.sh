#!/bin/sh
# ppe-v6-diag.sh - diagnose IPv6 routed flows blackholing under Airoha PPE HW offload

WATCH="${1:-5}"
DBG=/sys/kernel/debug
BIND="$DBG/ppe/bind"
N=/tmp/ppe_neigh.$$
S1=/tmp/ppe_snap1.$$
S2=/tmp/ppe_snap2.$$
trap 'rm -f "$N" "$S1" "$S2"' EXIT

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
echo "### Delegated-prefix routing (the /60 tell-tale) ################"
echo "  -- unreachable aggregate route(s) (present for /60+, absent for a bare /64):"
ip -6 route show table all 2>/dev/null | grep -i unreachable | sed 's/^/    /'
[ -z "$(ip -6 route show table all 2>/dev/null | grep -i unreachable)" ] && echo "    (none)"
echo "  -- on-link LAN prefixes:"
ip -6 route show 2>/dev/null | grep -vE "unreachable|default|fe80|via" | grep dev | sed 's/^/    /'

# --- capture two FOE snapshots + the neighbour table -------------------
ip -6 neigh show > "$N" 2>/dev/null
cat "$BIND" > "$S1" 2>/dev/null
sleep "$WATCH"
cat "$BIND" > "$S2" 2>/dev/null

echo
echo "### Hardware-bound IPv6 flows  (window = ${WATCH}s) #############"
echo "  legend: PKT_DELTA = packets the PPE forwarded in the window."
echo "          A climbing delta while the client sees nothing = HW black-hole."
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
echo "### Kernel route decision for each bound IPv6 dst ###############"
echo "  (download flows: dst = a LAN client; watch for 'unreachable' or wrong dev)"
for ip in $(awk '/IPv6 /{for(k=1;k<=NF;k++) if($k ~ /^orig=/){split(substr($k,6),a,"->"); split(a[2],p,":"); print p[1]":"p[2]":"p[3]":"p[4]":"p[5]":"p[6]":"p[7]":"p[8]}}' "$S2" | sort -u); do
	printf "  %-40s -> " "$ip"
	ip -6 route get "$ip" 2>/dev/null | head -1
done

echo
echo "=================================================================="
echo " Interpretation:"
echo "  * NEXTHOP_MAC matches a REACHABLE neighbour + PKT_DLT climbs + client"
echo "    still stalls  -> problem is NOT the next-hop; suspect PPE IPv6-route"
echo "    (non-NAT) handling itself -> keep the 'meta nfproto ipv4' workaround."
echo "  * NEXTHOP_MAC is NULL/00:00:00 or an unknown MAC while PKT_DLT climbs"
echo "    -> HW is black-holing: offload bound a wrong/stale next-hop. Capture"
echo "       this output + 'ip -6 route get <DST_IP>' for the bug report."
echo "  * PKT_DLT is 0 for the stalled flow -> HW isn't the forwarder; look at"
echo "    the software path / conntrack instead."
echo "=================================================================="
