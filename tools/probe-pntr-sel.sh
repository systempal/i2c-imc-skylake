#!/usr/bin/env bash
#
# READ-ONLY ON THE BUS. Tests whether the unexplored bits of the PCU command
# word encode an address-only ("pointer select") transaction, which is what
# SMBus Receive Byte and Send Byte need and what this driver cannot express
# today.
#
# Why bit 18 in particular. The command word bits the driver knows are:
#
#   b29 engine enable   b20 TSOD active   b19 GO   b17 word access
#   b15 write           b14:8 address     b7:0 register
#
# The interface Intel does document for the iMC channel functions (SMBCMD,
# datasheet ref. 614073 section 3.1.8) lays its control bits out as:
#
#   b31 CMD_TRIGGER   b30 PNTR_SEL   b29 WORD_ACCESS   b28:27 rw
#
# There PNTR_SEL sits immediately above WORD_ACCESS. In the PCU word, word
# access is bit 17, so the same adjacency puts a pointer-select bit at 18.
# Bit 17 was itself unexplored until it turned out to be word access, so the
# guess has precedent on this engine.
#
# An earlier sweep of this register (2026-06-12, furyrs docs/linux-rgb-protocol.md)
# covered bits 31:20 only, so 16 and 18 have never been tried. Both are swept
# here.
#
# The test is a discriminator, not a bit flip in the dark. SPD 0x50 answers
# with known values, and an EEPROM auto-increments its internal pointer after
# a read. So:
#
#   1. ordinary read of register 0x00  -> 0x23, pointer left at 0x01
#   2. same read with the candidate bit set
#        - returns something other than 0x23  -> the register byte was not
#          sent, the engine read from the pointer: address-only transaction
#        - returns 0x23 again                 -> the bit changed nothing
#
# Repeated at register 0x02 (-> 0x0c) so a single coincidence cannot pass.
#
# Nothing is written to the bus: reads only, against an EEPROM, and never to
# the page-select addresses 0x36/0x37, so the global DDR4 page latch does not
# move. DATA is restored with GO masked on every exit path.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

COMMAND_TOGGLE=$((1 << 29))
GO_BIT=$((1 << 19))
TSOD_ACTIVE_BIT=$((1 << 20))
STAT_BUSY=1
STAT_ERROR=2

ADDR=0x50
CHANNEL=0
CANDIDATES=(16 18)
WALK=8
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--addr) ADDR=$2; shift 2 ;;
	--channel) CHANNEL=$2; shift 2 ;;
	--bits) IFS=, read -r -a CANDIDATES <<<"$2"; shift 2 ;;
	-h|--help)
		sed -n '3,40p' "$0"
		echo "usage: $0 --i-understand [--addr 0xNN] [--channel 0|1] [--bits 16,18]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "Issues SMBus read transactions from userspace. Re-run with --i-understand." >&2
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

((original & GO_BIT)) && die "GO already set, refusing"
((original & TSOD_ACTIVE_BIT)) && die "TSOD_ACTIVE set, refusing"
((status0 & STAT_BUSY)) && die "engine BUSY, refusing"

restore()
{
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$((original & ~GO_BIT))")" || true
}
trap restore EXIT

# read_once <command> -> echoes "<status> <ctrl> <byte>"; returns 1 on NACK.
read_once()
{
	local command=$1 i data status ctrl

	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$command")"

	for ((i = 0; i < 60; i++)); do
		data=$(read_reg "$BDF" "$REG_DATA")
		((data & GO_BIT)) || break
		sleep 0.005
	done

	status=$(read_reg "$BDF" "$REG_STAT")
	ctrl=$(read_reg "$BDF" "$REG_CTRL")
	printf '%s %s 0x%02x\n' "$status" "$ctrl" "$((ctrl & 0xff))"
	! ((status & STAT_ERROR))
}

plain()
{
	printf '%d' $((COMMAND_TOGGLE | GO_BIT | (ADDR << 8) | $1))
}

echo "device $BDF channel $CHANNEL, target $ADDR"
echo "DATA before: $original   STATUS before: $status0"
echo

echo "=== baseline: ordinary reads, no candidate bit ==="
declare -A baseline
for reg in 0x00 0x02; do
	if out=$(read_once "$(plain "$reg")"); then
		baseline[$reg]=${out##* }
		printf '  reg %s -> %s   (status %s ctrl %s)\n' \
			"$reg" "${baseline[$reg]}" "${out%% *}" "$(awk '{print $2}' <<<"$out")"
	else
		printf '  reg %s -> NACK (status %s)\n' "$reg" "${out%% *}"
		baseline[$reg]=NACK
	fi
done
echo

verdict=none
for bit in "${CANDIDATES[@]}"; do
	candidate=$((1 << bit))
	printf '=== candidate BIT(%d) = 0x%08x ===\n' "$bit" "$candidate"
	differed=0
	for reg in 0x00 0x02; do
		# Prime the EEPROM pointer with an ordinary read, then repeat it
		# with the candidate bit set. A pointer-select transaction skips
		# the register byte and answers from the auto-incremented pointer.
		read_once "$(plain "$reg")" >/dev/null || true
		if out=$(read_once "$(( $(plain "$reg") | candidate ))"); then
			byte=${out##* }
			printf '  after reg %s -> %s   (baseline %s, status %s)\n' \
				"$reg" "$byte" "${baseline[$reg]}" "${out%% *}"
			[[ "$byte" != "${baseline[$reg]}" ]] && differed=$((differed + 1))
		else
			printf '  after reg %s -> NACK (status %s)\n' "$reg" "${out%% *}"
			differed=$((differed + 1))
		fi
	done

	if ((differed == 2)); then
		echo "  -> both reads changed: this bit alters the transaction."
		verdict=$bit
	elif ((differed == 1)); then
		echo "  -> one read changed. Not conclusive; could be an SPD byte"
		echo "     that happens to equal its neighbour. Re-run to confirm."
	else
		echo "  -> identical to baseline: the bit is inert on reads."
	fi
	echo
done

# A bit that merely perturbs the answer is not proof of a pointer-select. The
# proof is that consecutive transactions walk the EEPROM: prime the pointer with
# an ordinary read, then issue the candidate repeatedly and check the answers
# follow the device's own byte sequence.
if [[ "$verdict" != none ]]; then
	candidate=$((1 << verdict))
	printf '=== walk: %d consecutive BIT(%d) reads after priming at 0x00 ===\n' \
		"$WALK" "$verdict"
	read_once "$(plain 0x00)" >/dev/null || true
	walked=()
	for ((i = 0; i < WALK; i++)); do
		if out=$(read_once "$(( $(plain 0x00) | candidate ))"); then
			walked+=("${out##* }")
		else
			walked+=(NACK)
		fi
	done
	printf '  bytes 0x01.. : %s\n' "${walked[*]}"
	echo "  compare against an ordinary dump of the same range: if they match,"
	echo "  the engine is issuing a genuine address-only read."
	echo
fi

echo "=== verdict ==="
if [[ "$verdict" == none ]]; then
	cat <<-EOF
	NO ADDRESS-ONLY ENCODING FOUND in bits ${CANDIDATES[*]}.
	Every candidate left the transaction unchanged, so the engine still
	sends a register byte. SMBus Receive Byte and Send Byte cannot be
	implemented honestly on this command word, and ee1004 (and therefore
	decode-dimms) stays out of reach through this interface.
	EOF
else
	cat <<-EOF
	BIT($verdict) CHANGES THE TRANSACTION.
	Both probe reads returned something other than the register they named,
	which is what an address-only transaction looks like. Next step is to
	confirm the returned byte tracks the EEPROM pointer rather than being
	another deterministic transform of the command word: read a known
	sequence of registers and check the answers follow it.
	EOF
fi
