#!/bin/sh
# npu-reboot-guard.sh - safety net for patch 031 (avoid-stale-npu-wcid-reuse).
# Tunables (env, set in the init script): THRESHOLD (1000), REBOOT_HOUR (03 = 3am).

THRESHOLD="${THRESHOLD:-1000}"
REBOOT_HOUR="${REBOOT_HOUR:-03}"      # 24h clock, two digits
CNT=/tmp/npu-reboot-guard.count
ARMED=/tmp/npu-reboot-guard.armed

echo 0 > "$CNT"
rm -f "$ARMED"
logger -t npu-reboot-guard "started: will schedule a ${REBOOT_HOUR}:00 reboot after ${THRESHOLD} (re)associations"

iw event 2>/dev/null | while read -r line; do
	case "$line" in
	*"new station"*)
		c=$(( $(cat "$CNT" 2>/dev/null) + 1 ))
		echo "$c" > "$CNT"
		[ $(( c % 100 )) -eq 0 ] && logger -t npu-reboot-guard "count=$c"

		if [ "$c" -ge "$THRESHOLD" ] && [ ! -f "$ARMED" ]; then
			touch "$ARMED"
			logger -t npu-reboot-guard "reached $c associations - arming reboot for ${REBOOT_HOUR}:00"
			# wait until the reboot hour, then reset the box
			(
				while [ "$(date +%H)" != "$REBOOT_HOUR" ]; do sleep 300; done
				logger -t npu-reboot-guard "rebooting now to reset the stale-wcid pool (count=$c)"
				sync
				sleep 2
				reboot
			) &
		fi
		;;
	esac
done
