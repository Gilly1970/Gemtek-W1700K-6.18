#!/bin/sh
# Custom packet-steering for AN7581: threaded NAPI off + RPS=e on airoha_eth.
# Invoked by /etc/init.d/packet_steering on boot + every network reload.
# Without this override, upstream packet-steering.uc would write rps_cpus=1
# (CPU0 only). With threaded NAPI off + RPS=e, RX work spreads across CPUs 1-3
# and bursty UDP RX loss drops dramatically (24% -> 5%, +25% throughput).

for dev in eth0 lan2 wan; do
    # threaded NAPI off — DSA conduit (eth0) exposes the file but the write is "Not supported"
    [ -e "/sys/class/net/$dev/threaded" ] && echo 0 > "/sys/class/net/$dev/threaded" 2>/dev/null
    for q in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [ -w "$q" ] && echo e > "$q" 2>/dev/null
    done
done

exit 0
