#!/usr/bin/env bash
#
# WRITES TO HARDWARE. Answers the question that decided this driver's config
# access method: does a command written through CF8/CFC actually start an SMBus
# transaction, or only land in the register?
#
# It does start one. That result retired an earlier plan to reach the registers
# through ECAM with a PCI-core change; the driver uses the ordinary config
# accessors instead. Kept so anyone can reproduce it on their own board.
#
# tools/probe-cf8-write.sh already showed that the register itself is writable
# through CF8/CFC. This issues a full command with the GO bit set and watches
# whether the engine acts on it.
#
# The target defaults to a read of address 0x77, which is not populated, so the
# only thing that can happen on the bus is an address NACK - the same operation
# test-smoke.sh already performs through the driver. The original DATA value is
# restored with GO masked on every exit path.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMMAND_TOGGLE=$((1 << 29))
GO_BIT=$((1 << 19))
TSOD_ACTIVE_BIT=$((1 << 20))
STAT_BUSY=1
STAT_ERROR=2

ADDR=0x77
REG=0x00
CHANNEL=0
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--addr) ADDR=$2; shift 2 ;;
	--reg) REG=$2; shift 2 ;;
	--channel) CHANNEL=$2; shift 2 ;;
	-h|--help)
		sed -n '3,15p' "$0"
		echo "usage: $0 --i-understand [--addr 0xNN] [--reg 0xNN] [--channel 0|1]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "This issues an SMBus read transaction from userspace. Re-run with --i-understand." >&2
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
original=$(read_reg "$BDF" "$REG_DATA")
status0=$(read_reg "$BDF" "$REG_STAT")
ctrl0=$(read_reg "$BDF" "$REG_CTRL")

echo "device:  $BDF, channel $CHANNEL"
echo "target:  read address $ADDR register $REG"
echo "DATA   before: $original"
echo "STATUS before: $status0"
echo "CTRL   before: $ctrl0"
echo

((original & GO_BIT)) && die "GO already set, refusing"
((original & TSOD_ACTIVE_BIT)) && die "TSOD_ACTIVE set, refusing"
((status0 & STAT_BUSY)) && die "engine BUSY, refusing"

restore()
{
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$((original & ~GO_BIT))")" || true
	echo
	echo "DATA restored to $(read_reg "$BDF" "$REG_DATA")"
}
trap restore EXIT

issue()
{
	local command=$1 label=$2
	local i data status ctrl go_seen=no changed=no

	printf '=== %s: writing 0x%08x ===\n' "$label" "$command"
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$command")"

	for i in $(seq 1 40); do
		data=$(read_reg "$BDF" "$REG_DATA")
		status=$(read_reg "$BDF" "$REG_STAT")
		((data & GO_BIT)) && go_seen=yes
		[[ "$status" != "$status0" ]] && changed=yes
		if ((i <= 3)) || [[ "$changed" == yes ]]; then
			printf '  poll %-2d DATA=%s STATUS=%s\n' "$i" "$data" "$status"
		fi
		((data & GO_BIT)) || break
		sleep 0.005
	done

	data=$(read_reg "$BDF" "$REG_DATA")
	status=$(read_reg "$BDF" "$REG_STAT")
	ctrl=$(read_reg "$BDF" "$REG_CTRL")

	echo "  final DATA=$data STATUS=$status CTRL=$ctrl"
	echo "  GO observed set: $go_seen"
	echo "  STATUS changed:  $changed  (baseline $status0)"
	if ((status & STAT_ERROR)); then
		echo "  -> ERROR/NACK bit set: the engine ran the transaction and the"
		echo "     device did not answer, which is the expected result here."
	fi
	echo
}

# 1: exactly what the driver writes - toggle bit forced to 1.
issue $((COMMAND_TOGGLE | GO_BIT | (ADDR << 8) | REG)) "same toggle as the driver"

# 2: the toggle bit inverted relative to what is in the register now, in case
#    the engine latches a command on a change of that bit rather than on GO.
issue $(( ((original ^ COMMAND_TOGGLE) & COMMAND_TOGGLE) | GO_BIT | (ADDR << 8) | REG )) \
	"toggle bit inverted"

echo "=== verdict ==="
final_status=$(read_reg "$BDF" "$REG_STAT")
if [[ "$final_status" != "$status0" ]]; then
	cat <<-EOF
	CF8/CFC STARTED A TRANSACTION.
	STATUS moved from $status0 to $final_status without any ECAM access.
	No ECAM access is needed: the driver can use pci_read_config_dword()
	and pci_write_config_dword() like any other driver. This is the
	result the current driver is built on.
	EOF
else
	cat <<-EOF
	NO TRANSACTION.
	The register accepted the write (probe-cf8-write.sh proved that) but the
	engine did not act on it: STATUS never moved from $status0. On this board
	the failure would not be a filtered write but a command the engine
	ignores when it arrives this way, and the driver's assumption that the
	ordinary config accessors are enough would not hold here.
	EOF
fi
