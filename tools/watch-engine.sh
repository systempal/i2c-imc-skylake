#!/usr/bin/env bash
# Report changes to the iMC SMBus engine registers that Linux did not cause.
# Read-only. Run with the driver unloaded so anything observed is firmware.
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

SECONDS_TOTAL=3600
INTERVAL=1

while (($#)); do
	case $1 in
	--seconds) SECONDS_TOTAL=$2; shift 2 ;;
	--interval) INTERVAL=$2; shift 2 ;;
	-h|--help)
		echo "usage: $0 [--seconds N] [--interval N]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

require_root
require_cmd lspci setpci awk

BDF=$(find_pcu)

if driver_is_loaded; then
	echo "warning: i2c-imc-skylake is loaded; changes may be caused by Linux." >&2
	echo "         unload it for a clean firmware-activity measurement." >&2
fi

echo "device:   $BDF"
echo "duration: ${SECONDS_TOTAL}s, sampling every ${INTERVAL}s"
echo "started:  $(date -Is)"
echo

mapfile -t previous < <(snapshot_regs "$BDF")
printf 'baseline: %s\n' "${previous[*]}"

changes=0
samples=0
deadline=$((SECONDS + SECONDS_TOTAL))

while ((SECONDS < deadline)); do
	sleep "$INTERVAL"
	mapfile -t current < <(snapshot_regs "$BDF")
	((samples++))

	for i in "${!current[@]}"; do
		if [[ "${current[i]}" != "${previous[i]}" ]]; then
			printf '%s CHANGE %s -> %s\n' \
				"$(date -Is)" "${previous[i]}" "${current[i]}"
			((changes++))
		fi
	done
	previous=("${current[@]}")
done

echo
echo "finished: $(date -Is)"
echo "samples:  $samples"
echo "changes:  $changes"
echo
if ((changes == 0)); then
	echo "RESULT: no foreign activity observed on this system over ${SECONDS_TOTAL}s."
else
	echo "RESULT: the engine is in use by something other than Linux."
	echo "        Do not load i2c-imc-skylake on this system."
fi
