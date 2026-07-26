#!/usr/bin/env bash
#
# WRITES TO THE BUS. Tests whether the pointer-select bit found by
# tools/probe-pntr-sel.sh also produces an SMBus Send Byte, the write half of
# I2C_FUNC_SMBUS_BYTE, which ee1004 needs to select a DDR4 SPD page.
#
# The target is the page-select address 0x36 or 0x37, never an EEPROM. Those
# addresses hold a single latch and store no data: the only effect a write can
# have there is to select page 0 or page 1. Nothing is written to 0x50-0x57.
#
# The test verifies itself. A DDR4 SPD is 512 bytes reached through a 256-byte
# window, so which page is latched is visible in the data: on page 0 byte 0x00
# is 0x23 (the JEDEC "512 byte SPD" code), on page 1 the same offset shows
# byte 0x100 instead, which is not 0x23. Issue the Send Byte, read byte 0x00
# back, and the page state is the answer.
#
# --restore is the safe first run. It targets a channel already latched on page
# 1 and selects page 0, so a working Send Byte repairs that channel and a
# broken one leaves it exactly as it was found. There is no outcome worse than
# the starting state.
#
# --flip runs the full round trip on a channel already on page 0: select page 1,
# confirm the data moved, select page 0 again, confirm it came back. Use it only
# after --restore has shown the encoding works.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMMAND_TOGGLE=$((1 << 29))
GO_BIT=$((1 << 19))
PNTR_SEL_BIT=$((1 << 18))
TSOD_ACTIVE_BIT=$((1 << 20))
WRITE_OPERATION=$((1 << 15))
STAT_BUSY=1
STAT_ERROR=2

SPD_ADDR=0x50
PAGE0_ADDR=0x36
PAGE1_ADDR=0x37
SPD_PAGE0_BYTE0=0x23

CHANNEL=0
MODE=restore
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--channel) CHANNEL=$2; shift 2 ;;
	--restore) MODE=restore; shift ;;
	--flip) MODE=flip; shift ;;
	-h|--help)
		sed -n '3,24p' "$0"
		echo "usage: $0 --i-understand --channel 0|1 [--restore|--flip]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "This writes to the SPD page-select address. Re-run with --i-understand." >&2
	exit 2
}

require_root
require_cmd lspci setpci awk

case $CHANNEL in
0) REG_DATA=$REG_CH0_DATA; REG_STAT=$REG_CH0_STAT; REG_CTRL=$REG_CH0_CTRL ;;
1) REG_DATA=$REG_CH1_DATA; REG_STAT=$REG_CH1_STAT; REG_CTRL=$REG_CH1_CTRL ;;
*) die "channel must be 0 or 1" ;;
esac

driver_is_loaded && die "unload i2c-imc-skylake first"

BDF=$(find_pcu)
original_data=$(read_reg "$BDF" "$REG_DATA")
original_ctrl=$(read_reg "$BDF" "$REG_CTRL")
status0=$(read_reg "$BDF" "$REG_STAT")

((original_data & GO_BIT)) && die "GO already set, refusing"
((original_data & TSOD_ACTIVE_BIT)) && die "TSOD_ACTIVE set, refusing"
((status0 & STAT_BUSY)) && die "engine BUSY, refusing"

restore()
{
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$((original_data & ~GO_BIT))")" || true
	setpci -s "$BDF" "$REG_CTRL.L=$(printf '%08x' "$original_ctrl")" || true
}
trap restore EXIT

# wait_idle -> echoes the final status
wait_idle()
{
	local i data

	for ((i = 0; i < 60; i++)); do
		data=$(read_reg "$BDF" "$REG_DATA")
		((data & GO_BIT)) || break
		sleep 0.005
	done
	read_reg "$BDF" "$REG_STAT"
}

# spd_byte0 -> echoes the byte at SPD offset 0x00 as 0x%02x
spd_byte0()
{
	local ctrl

	setpci -s "$BDF" \
		"$REG_DATA.L=$(printf '%08x' "$((COMMAND_TOGGLE | GO_BIT | (SPD_ADDR << 8)))")"
	wait_idle >/dev/null
	ctrl=$(read_reg "$BDF" "$REG_CTRL")
	printf '0x%02x\n' "$((ctrl & 0xff))"
}

# send_byte <addr> -> echoes the status; returns 1 if the device NACKed
send_byte()
{
	local addr=$1 command status

	command=$((COMMAND_TOGGLE | GO_BIT | PNTR_SEL_BIT | WRITE_OPERATION | (addr << 8)))
	# Data byte in the same place a BYTE_DATA write puts it. The page-select
	# devices ignore it; it is set to zero so nothing meaningful is sent.
	setpci -s "$BDF" "$REG_CTRL.L=00000000"
	printf '  Send Byte to %s: command 0x%08x\n' "$addr" "$command"
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$command")"
	status=$(wait_idle)
	printf '  status 0x%s\n' "${status#0x}"
	# A NACK here is expected and harmless: some modules latch the page but
	# do not acknowledge, which is why ee1004 rechecks instead of giving up.
	! ((status & STAT_ERROR))
}

echo "device $BDF channel $CHANNEL, mode $MODE"
echo "DATA before: $original_data   CTRL before: $original_ctrl   STATUS: $status0"
echo

before=$(spd_byte0)
printf 'SPD 0x50 byte 0x00 before: %s\n' "$before"

case $MODE in
restore)
	if [[ "$before" == "$SPD_PAGE0_BYTE0" ]]; then
		die "channel $CHANNEL is already on page 0, nothing to restore (use --flip)"
	fi
	echo "channel is not on page 0. Selecting page 0."
	send_byte "$PAGE0_ADDR" || echo "  (device did not ack; checking anyway)"
	after=$(spd_byte0)
	printf 'SPD 0x50 byte 0x00 after:  %s\n\n' "$after"

	if [[ "$after" == "$SPD_PAGE0_BYTE0" ]]; then
		cat <<-EOF
		=== SEND BYTE WORKS ===
		The page-select address accepted an address-only write: byte 0x00 went
		from $before to $after, the JEDEC page-0 value. Bit 18 encodes SMBus
		Send Byte as well as Receive Byte, so I2C_FUNC_SMBUS_BYTE can be
		implemented honestly and ee1004 can bind.

		Channel $CHANNEL is also back on page 0, which is where it should have
		been.
		EOF
	else
		cat <<-EOF
		=== NO PAGE CHANGE ===
		Byte 0x00 is still $after. Either the write did not reach the bus in
		Send Byte form, or this channel is not on page 1 for the reason
		assumed. The channel is exactly as it was found; nothing was made
		worse. Do not implement Send Byte on this encoding.
		EOF
	fi
	;;
flip)
	[[ "$before" == "$SPD_PAGE0_BYTE0" ]] ||
		die "channel $CHANNEL is not on page 0 to begin with (byte 0x00 = $before)"

	echo "selecting page 1"
	send_byte "$PAGE1_ADDR" || echo "  (no ack; checking anyway)"
	flipped=$(spd_byte0)
	printf 'byte 0x00 on page 1: %s\n\n' "$flipped"

	echo "selecting page 0 again"
	send_byte "$PAGE0_ADDR" || echo "  (no ack; checking anyway)"
	back=$(spd_byte0)
	printf 'byte 0x00 restored:  %s\n\n' "$back"

	echo "=== result ==="
	if [[ "$flipped" != "$before" && "$back" == "$before" ]]; then
		echo "Round trip clean: the page moved and came back. Send Byte confirmed."
	elif [[ "$back" != "$before" ]]; then
		echo "WARNING: the channel did not return to page 0 (byte 0x00 = $back)."
		echo "Re-run with --restore to put it back."
	else
		echo "The page never moved. Send Byte is not encoded this way."
	fi
	;;
esac
