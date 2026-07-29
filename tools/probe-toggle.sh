#!/usr/bin/env bash
#
# READ-ONLY bus traffic. Tests whether the engine executes a command word
# with bit 29 (the command toggle) at either polarity.
#
# Why it matters: a driver that alternated bit 29 on every command could
# always tell a command write that never reaches the CMD register apart
# from the stale word of the previous, otherwise identical, command. The done
# bits are latched, so STATUS cannot make that distinction, and two identical
# commands differ in no other bit. The scheme only works if the engine
# executes commands with the bit at 0 as readily as with it at 1. Every word
# ever observed from firmware has the bit set, so polarity 0 is the case that
# needs proving.
#
# Measured 2026-07-28 on the test system: exit 3, TOGGLE FIXED. The engine
# consumes GO but sets the error bit for every command with bit 29 clear
# (8/8; the bit is stored as written, interleaved toggle=1 reads work).
# Alternation was reverted; the limitation is documented at
# imc_command_landed() in the driver instead.
#
# What it does: BYTE_DATA reads of SPD registers 0x00-0x03 at 0x50, first all
# with toggle=1 (baseline), then the same reads with toggle=0, then an
# alternating run. Reads only; no device state is touched. The original
# CMD/DATA registers are restored on exit.
#
# Verdicts (exit code):
#   0  TOGGLE FREE  - polarity 0 behaves identically. Alternating is safe.
#   3  TOGGLE FIXED - polarity 0 is not executed (GO stuck, error, or wrong
#                     data). Do not alternate.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMMAND_TOGGLE=$((1 << 29))
GO_BIT=$((1 << 19))
TSOD_ACTIVE_BIT=$((1 << 20))
STAT_BUSY=1
STAT_ERROR=2

SPD_ADDR=0x50
CHANNEL=0
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--channel) CHANNEL=$2; shift 2 ;;
	-h|--help)
		sed -n '3,24p' "$0"
		echo "usage: $0 --i-understand [--channel 0|1]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "This drives the iMC SMBus engine (reads only). Re-run with --i-understand." >&2
	exit 2
}

require_root
require_cmd lspci setpci awk

# common.sh predates the v4 register naming: its *_DATA is the command
# register (0x9c/0xa0) and its *_CTRL is the data latch (0xb4/0xb8).
case $CHANNEL in
0) REG_CMD=$REG_CH0_DATA; REG_STAT=$REG_CH0_STAT; REG_DAT=$REG_CH0_CTRL ;;
1) REG_CMD=$REG_CH1_DATA; REG_STAT=$REG_CH1_STAT; REG_DAT=$REG_CH1_CTRL ;;
*) die "channel must be 0 or 1" ;;
esac

driver_is_loaded && die "unload i2c-imc-skylake first"

BDF=$(find_pcu)
original_cmd=$(read_reg "$BDF" "$REG_CMD")
original_dat=$(read_reg "$BDF" "$REG_DAT")
status0=$(read_reg "$BDF" "$REG_STAT")

((original_cmd & GO_BIT)) && die "GO already set, refusing"
((original_cmd & TSOD_ACTIVE_BIT)) && die "TSOD_ACTIVE set, refusing"
((status0 & STAT_BUSY)) && die "engine BUSY, refusing"

restore()
{
	setpci -s "$BDF" "$REG_CMD.L=$(printf '%08x' "$((original_cmd & ~GO_BIT))")" || true
	setpci -s "$BDF" "$REG_DAT.L=$(printf '%08x' "$original_dat")" || true
}
trap restore EXIT

# wait_go -> 0 if GO cleared, 1 if it stayed set (polarity rejected?)
wait_go()
{
	local i cmd

	for ((i = 0; i < 60; i++)); do
		cmd=$(read_reg "$BDF" "$REG_CMD")
		((cmd & GO_BIT)) || return 0
		sleep 0.005
	done
	return 1
}

go_stuck=0
bad_status=0
toggle_lost=0

# read_byte <reg> <polarity 0|1> -> echoes data byte, or "GO-STUCK"/"ERROR"
read_byte()
{
	local reg=$1 pol=$2 command cmd_after status

	command=$(((pol ? COMMAND_TOGGLE : 0) | GO_BIT | (SPD_ADDR << 8) | reg))
	setpci -s "$BDF" "$REG_CMD.L=$(printf '%08x' "$command")"
	if ! wait_go; then
		go_stuck=$((go_stuck + 1))
		# clear the stuck GO before the next attempt
		setpci -s "$BDF" \
			"$REG_CMD.L=$(printf '%08x' "$((command & ~GO_BIT))")"
		echo "GO-STUCK"
		return
	fi
	status=$(read_reg "$BDF" "$REG_STAT")
	if ((status & STAT_ERROR)); then
		bad_status=$((bad_status + 1))
		echo "ERROR"
		return
	fi
	# the engine must preserve the polarity it was given, or the driver's
	# landed-check readback comparison cannot rely on bit 29
	cmd_after=$(read_reg "$BDF" "$REG_CMD")
	if (((cmd_after & COMMAND_TOGGLE) != (pol ? COMMAND_TOGGLE : 0))); then
		toggle_lost=$((toggle_lost + 1))
	fi
	printf '0x%02x\n' "$(($(read_reg "$BDF" "$REG_DAT") & 0xff))"
}

echo "device $BDF channel $CHANNEL, SPD $SPD_ADDR"
echo "CMD before: $original_cmd   STATUS: $status0"
echo

declare -a baseline
echo "baseline, toggle=1:"
for reg in 0 1 2 3; do
	baseline[reg]=$(read_byte "$reg" 1)
	printf '  reg 0x%02x = %s\n' "$reg" "${baseline[$reg]}"
	[[ "${baseline[$reg]}" == GO-STUCK || "${baseline[$reg]}" == ERROR ]] &&
		die "baseline read failed; engine not usable even at toggle=1"
done

mismatch=0
echo "same reads, toggle=0:"
for reg in 0 1 2 3; do
	got=$(read_byte "$reg" 0)
	printf '  reg 0x%02x = %s (expect %s)\n' "$reg" "$got" "${baseline[$reg]}"
	[[ "$got" == "${baseline[$reg]}" ]] || mismatch=$((mismatch + 1))
done

echo "alternating run:"
pol=1
for i in 0 1 2 3 4 5 6 7; do
	reg=$((i % 4))
	pol=$((1 - pol))
	got=$(read_byte "$reg" "$pol")
	printf '  toggle=%d reg 0x%02x = %s (expect %s)\n' \
	       "$pol" "$reg" "$got" "${baseline[$reg]}"
	[[ "$got" == "${baseline[$reg]}" ]] || mismatch=$((mismatch + 1))
done

echo
echo "=== result ==="
echo "mismatches: $mismatch, GO stuck: $go_stuck, NACK/error: $bad_status, toggle not preserved: $toggle_lost"
if ((mismatch == 0 && go_stuck == 0 && bad_status == 0 && toggle_lost == 0)); then
	cat <<-EOF
	TOGGLE FREE: the engine executes both polarities and preserves the bit
	as written. Alternating the toggle per command is safe, and the v4
	landed-check can rely on bit 29 distinguishing consecutive commands.
	EOF
	exit 0
fi
cat <<-EOF
TOGGLE FIXED (or degraded): polarity 0 did not behave like polarity 1.
Do not alternate the toggle; revert the v4 toggle change and rely on the
readback check alone.
EOF
exit 3
