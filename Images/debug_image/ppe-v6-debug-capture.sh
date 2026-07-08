#!/bin/sh
# W1700K IPv6 PPE debug capture (disc #18)
# Run this ON THE ROUTER while an IPv6 iperf3/download is running on your LAN/WiFi client.
# It grabs the debug image's offload-path logging + the ppe-v6-diag snapshot,
# so a stalling box and a working box can be compared like-for-like.
#
# Usage:
#   1) copy ppe-v6-diag.sh to /tmp on the router
#   2) on your client:   iperf3 -c <your-v6-iperf-server> -R -t 30 -p <port>
#                        (or any sustained IPv6 download, e.g. a bufferbloat test)
#   3) ~3s later, on the router:   sh /tmp/ppe-v6-debug-capture.sh
#   4) note whether that transfer STALLED or COMPLETED (+ rough speed), then
#      paste the whole /tmp/ppe-v6-debug.log
OUT=/tmp/ppe-v6-debug.log

{
  echo "================= W1700K IPv6 PPE DEBUG CAPTURE ================="
  echo "date   : $(date)"
  echo "kernel : $(uname -a)"
  echo "offload: flow_offloading=$(uci -q get firewall.@defaults[0].flow_offloading) flow_offloading_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)  (need hw=1 for HW offload to engage)"
  echo
  echo "########## HOW TO READ THIS (important) ##########"
  echo "  The verdict is NOT PKT_DELTA. On AN7581 the NPU does not populate the"
  echo "  per-entry packet counter, so 'packets=0' / PKT_DLT=0 shows up even for"
  echo "  flows that forward perfectly. Judge by these instead:"
  echo "    1) Did the transfer actually STALL or COMPLETE (and roughly what speed)?"
  echo "    2) The interface RX-vs-TX table: WAN RX climbing while the client-facing"
  echo "       TX (LAN/WiFi) stays ~flat = real black-hole."
  echo "    3) The 'airoha_ppe DBG v6:' lines below: which egress PATH each flow took"
  echo "       (WDMA-wifi vs GDM-eth pse_port=2 loopback) and the vlan= value."
  echo
  echo ">>> the 15s diag window starts in 3s -- make sure your download is running <<<"
  sleep 3
  echo
  echo "########## ppe-v6-diag (15s window) ##########"
  if [ -f /tmp/ppe-v6-diag.sh ]; then
    sh /tmp/ppe-v6-diag.sh 15
  else
    echo "!! /tmp/ppe-v6-diag.sh not found -- copy it to /tmp first"
  fi
  echo
  echo "########## airoha_ppe DBG offload-path lines (last 60) ##########"
  echo "# path=WDMA-wifi  = flow egresses to a WiFi client (WED path)"
  echo "# path=GDM-eth pse_port=2 loopback=1 = WAN uplink via GDM2 loopback"
  echo "# path=GDM-eth ... lan=1 = wired LAN egress"
  echo "# (compare vlan= : 0 = untagged, >0 = tagged WAN -- the suspected trigger)"
  dmesg | grep 'airoha_ppe DBG' | tail -60 || true
  if ! dmesg | grep -q 'airoha_ppe DBG'; then
    echo "(NONE found -- either no IPv6 flow offloaded during the window,"
    echo " or this is NOT the debug image. Confirm the download was running + hw=1.)"
  fi
  echo "================= END ================="
} > "$OUT" 2>&1
cat "$OUT"
