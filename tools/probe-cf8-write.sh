#!/usr/bin/env bash
#
# WRITES TO HARDWARE. Answers two questions the submission still owes:
#
#   1. does a CF8/CFC dword write to the iMC SMBus command register take
#      effect on this board?
#   2. does that write raise an SMI?
#
# It modifies only the register/offset field, DATA[7:0], while the GO bit is
# clear, so no SMBus transaction is issued, and it restores the original value
# on every exit path. It refuses to run if the engine is busy, if a transaction
# is armed, if TSOD is active, or if the driver is loaded.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

GO_BIT=$((1 << 19))
TSOD_ACTIVE_BIT=$((1 << 20))
STAT_BUSY=1

CHANNEL=0
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--channel) CHANNEL=$2; shift 2 ;;
	-h|--help)
		sed -n '3,14p' "$0"
		echo "usage: $0 --i-understand [--channel 0|1]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

if ! $CONFIRMED; then
	cat >&2 <<-'EOF'
	This script writes to a register of the memory controller's SMBus engine.

	It is written to be a no-op for the bus: the GO bit stays clear, so no
	SMBus transaction is issued, and the original register value is restored
	before the script exits. It is still a write to firmware-owned hardware.

	Re-run with --i-understand to proceed.
	EOF
	exit 2
fi

require_root
require_cmd lspci setpci awk

case $CHANNEL in
0) REG_DATA=$REG_CH0_DATA; REG_STAT=$REG_CH0_STAT ;;
1) REG_DATA=$REG_CH1_DATA; REG_STAT=$REG_CH1_STAT ;;
*) die "channel must be 0 or 1" ;;
esac

if ! command -v rdmsr >/dev/null; then
	echo "warning: rdmsr not found, the SMI question will stay unanswered." >&2
	echo "         install msr-tools and 'modprobe msr' for the full result." >&2
fi

driver_is_loaded && die "unload i2c-imc-skylake first"

BDF=$(find_pcu)
echo "device:  $BDF"
echo "channel: $CHANNEL (DATA at $REG_DATA, STATUS at $REG_STAT)"
echo

original=$(read_reg "$BDF" "$REG_DATA")
status=$(read_reg "$BDF" "$REG_STAT")
echo "DATA   before: $original"
echo "STATUS before: $status"

((original & GO_BIT)) && die "GO is set: a transaction is armed, refusing"
((original & TSOD_ACTIVE_BIT)) &&
	die "TSOD_ACTIVE is set: firmware is using the engine, refusing"
((status & STAT_BUSY)) && die "engine is BUSY, refusing"

restore()
{
	setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$original")" || true
	echo "DATA restored to $(read_reg "$BDF" "$REG_DATA")"
}
trap restore EXIT

# Flip the low byte to something that is certainly different, GO still clear.
probe=$(( (original & ~0xff) | ( ((original & 0xff) ^ 0x5a) & 0xff ) ))
probe_hex=$(printf '0x%08x' "$probe")

smi_before=$(read_smi_count)
echo
echo "writing $probe_hex through CF8/CFC (setpci)..."
setpci -s "$BDF" "$REG_DATA.L=$(printf '%08x' "$probe")"
readback=$(read_reg "$BDF" "$REG_DATA")
smi_after=$(read_smi_count)

echo "DATA after write: $readback"
echo

echo "=== result 1: did the write take effect? ==="
if [[ "$readback" == "$probe_hex" ]]; then
	echo "STUCK - the CF8/CFC write reached the register."
	echo "        The premise of the ECAM patch does not hold on this board;"
	echo "        do not claim CF8/CFC writes are dropped."
else
	echo "DROPPED - wrote $probe_hex, read back $readback."
	echo "          Confirms that CF8/CFC writes to this function do not"
	echo "          take effect on this board."
fi
echo

echo "=== result 2: was an SMI raised? ==="
if ((smi_before < 0 || smi_after < 0)); then
	echo "UNKNOWN - MSR_SMI_COUNT not readable (need msr-tools + modprobe msr)."
else
	delta=$((smi_after - smi_before))
	echo "MSR_SMI_COUNT: $smi_before -> $smi_after (delta $delta)"
	if ((delta == 0)); then
		echo "NO SMI - the behaviour must not be attributed to SMM."
	else
		echo "SMI RAISED - System Management Mode is involved; say so, with"
		echo "             this number, in the changelog."
	fi
fi
