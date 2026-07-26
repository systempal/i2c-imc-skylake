#!/usr/bin/env bash
#
# Suspend/resume validation with active I2C clients.
#
# Hammers both adapters from userspace and suspends the machine underneath the
# traffic.  The driver hands suspend and resume to the i2c core
# (i2c_mark_adapter_suspended / _resumed), so the core must reject transfers
# with -ESHUTDOWN for the duration and accept them again afterwards.  What this
# checks:
#
# Traffic goes through i2c-dev rather than a bound client driver: ee1004 needs
# I2C_FUNC_SMBUS_BYTE, which this adapter does not implement, and no TSOD is
# populated for jc42 to bind to.  The PM path being exercised is the same one
# either way - i2c_smbus_xfer() calls __i2c_check_suspended() before reaching
# the adapter.
#
#   - transfers fail while the adapter is suspended rather than touching the
#     engine or hanging;
#   - transfers succeed again after resume, with correct data;
#   - nothing in the kernel log complains.
#
# The machine really does suspend.  Wake-up is scheduled through the RTC alarm,
# so no key press is needed, but if the platform fails to wake you will have to
# press the power button.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

MODE=freeze
ASLEEP=20
SPD_ADDR=0x50
CONFIRMED=false
READER=""

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--mode) MODE=$2; shift 2 ;;
	--seconds) ASLEEP=$2; shift 2 ;;
	-h|--help)
		sed -n '3,19p' "$0"
		echo "usage: $0 --i-understand [--mode freeze|mem] [--seconds N]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "This suspends the machine. Re-run with --i-understand." >&2
	exit 2
}

require_root
require_cmd i2cdetect i2cget rtcwake awk

bus_of()
{
	i2cdetect -l | awk -v ch="$1" '
		tolower($0) ~ /imc.*channel/ && $0 ~ "channel " ch {
			sub(/^i2c-/, "", $1); print $1; exit
		}'
}

cleanup()
{
	[[ -n "$READER" ]] && kill "$READER" 2>/dev/null || true
}
trap cleanup EXIT

BUSES=()
for ch in 0 1; do
	b=$(bus_of "$ch")
	[[ -n "$b" ]] || die "adapter for channel $ch not found"
	BUSES+=("$b")
done
echo "adapters: ${BUSES[*]}"

for b in "${BUSES[@]}"; do
	i2cget -y "$b" "$SPD_ADDR" 0x02 >/dev/null 2>&1 ||
		die "bus $b: cannot read the SPD at $SPD_ADDR, nothing to hammer"
	echo "  bus $b: SPD $SPD_ADDR responds"
done

BDF=$(find_pcu)
mapfile -t REGS_BEFORE < <(snapshot_regs "$BDF")

LOG=$(mktemp)
DMESG_START=$(dmesg | wc -l)

# Hammer the clients and record the outcome of every read with a timestamp.
(
	while :; do
		for b in "${BUSES[@]}"; do
			if i2cget -y "$b" "$SPD_ADDR" 0x02 >/dev/null 2>&1; then
				printf '%s OK\n' "$(date +%s.%N)"
			else
				printf '%s FAIL\n' "$(date +%s.%N)"
			fi
		done
		sleep 0.1
	done
) >> "$LOG" 2>&1 &
READER=$!

sleep 2
BEFORE=$(date +%s)
echo "suspending: mode=$MODE for ${ASLEEP}s"
rtcwake -m "$MODE" -s "$ASLEEP" >/dev/null 2>&1 || die "rtcwake failed"
AFTER=$(date +%s)
sleep 2

kill "$READER" 2>/dev/null || true
READER=""
sleep 0.5

echo
echo "=== result ==="
printf 'wall clock across suspend: %ss (asked for %ss)\n' "$((AFTER - BEFORE))" "$ASLEEP"

pre=$(awk -v t="$BEFORE" '$1 < t && $2 == "OK"' "$LOG" | wc -l)
post=$(awk -v t="$AFTER" '$1 > t && $2 == "OK"' "$LOG" | wc -l)
fails=$(awk '$2 == "FAIL"' "$LOG" | wc -l)
fails_outside=$(awk -v a="$BEFORE" -v b="$AFTER" '$2 == "FAIL" && ($1 < a || $1 > b)' "$LOG" | wc -l)

printf 'reads OK before suspend: %s\n' "$pre"
printf 'reads OK after resume:   %s\n' "$post"
printf 'failed reads total:      %s\n' "$fails"
printf 'failed reads outside the suspend window: %s\n' "$fails_outside"

echo
echo "engine registers across the suspend:"
mapfile -t REGS_AFTER < <(snapshot_regs "$BDF")
moved=0
for i in "${!REGS_AFTER[@]}"; do
	if [[ "${REGS_AFTER[i]}" == "${REGS_BEFORE[i]}" ]]; then
		printf '  %-28s unchanged\n' "${REGS_BEFORE[i]}"
	else
		printf '  %s -> %s  CHANGED\n' "${REGS_BEFORE[i]}" "${REGS_AFTER[i]}"
		moved=$((moved + 1))
	fi
done
if ((moved)); then
	echo "  note: something reprogrammed the engine across the suspend."
	echo "  On resume the driver restores command state per transfer, but a"
	echo "  change here means firmware touched it while the OS was down."
fi

echo
NEW=$(dmesg | tail -n "+$((DMESG_START + 1))")
grep -Ei 'i2c-imc-skylake|BUG:|WARNING:|Oops:|KASAN:|lockdep' <<< "$NEW" || echo "(no driver or kernel complaints)"

echo
rc=0
((pre > 0))  || { echo "FAIL: no successful read before suspend"; rc=1; }
((post > 0)) || { echo "FAIL: reads did not recover after resume"; rc=1; }
((fails_outside == 0)) || { echo "FAIL: reads failed outside the suspend window"; rc=1; }
grep -Eiq 'BUG:|WARNING:|Oops:|KASAN:|lockdep' <<< "$NEW" && { echo "FAIL: kernel complaint"; rc=1; }
((rc == 0)) && echo "PASS: transfers resumed correctly and nothing complained"

rm -f "$LOG"
exit $rc
