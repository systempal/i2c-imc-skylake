# Shared helpers for the tools/ scripts. Sourced, not executed.
# shellcheck shell=bash

PCU_VENDOR_DEVICE=8086:2085

# Per-channel register offsets in the PCU function's config space.
REG_CH0_DATA=0x9c
REG_CH1_DATA=0xa0
REG_CH0_STAT=0xa8
REG_CH1_STAT=0xac
REG_CH0_CTRL=0xb4
REG_CH1_CTRL=0xb8

ALL_REGS=(
	"ch0.DATA:$REG_CH0_DATA"
	"ch1.DATA:$REG_CH1_DATA"
	"ch0.STAT:$REG_CH0_STAT"
	"ch1.STAT:$REG_CH1_STAT"
	"ch0.CTRL:$REG_CH0_CTRL"
	"ch1.CTRL:$REG_CH1_CTRL"
)

die()
{
	echo "error: $*" >&2
	exit 1
}

require_root()
{
	((EUID == 0)) || die "run as root"
}

require_cmd()
{
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null || die "missing command: $cmd"
	done
}

# Print the domain:bus:dev.fn of the PCU function, or fail.
find_pcu()
{
	local bdf

	bdf=$(lspci -Dn -d "$PCU_VENDOR_DEVICE" | awk 'NR == 1 { print $1 }')
	[[ -n "$bdf" ]] || die "PCI function $PCU_VENDOR_DEVICE not found"
	printf '%s\n' "$bdf"
}

# read_reg <bdf> <offset> -> 32-bit value as 0x%08x
read_reg()
{
	local bdf=$1 off=$2 raw

	raw=$(setpci -s "$bdf" "$off.L") || die "setpci read $off failed"
	printf '0x%08x\n' "$((16#$raw))"
}

# Snapshot every engine register into a "name=value" list.
snapshot_regs()
{
	local bdf=$1 entry name off

	for entry in "${ALL_REGS[@]}"; do
		name=${entry%%:*}
		off=${entry##*:}
		printf '%s=%s\n' "$name" "$(read_reg "$bdf" "$off")"
	done
}

# Sum of MSR_SMI_COUNT (0x34) across all CPUs. Prints -1 if unavailable.
read_smi_count()
{
	local cpu total=0 value

	command -v rdmsr >/dev/null || { echo -1; return; }
	for cpu in /dev/cpu/[0-9]*; do
		[[ -e "$cpu/msr" ]] || continue
		value=$(rdmsr -p "${cpu##*/}" -d 0x34 2>/dev/null) || continue
		total=$((total + value))
	done
	printf '%s\n' "$total"
}

driver_is_loaded()
{
	lsmod | awk '$1 == "i2c_imc_skylake" { found = 1 } END { exit !found }'
}
