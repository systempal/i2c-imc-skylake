#!/usr/bin/env bash
# Read-only smoke test for i2c-imc-skylake.
set -euo pipefail

PASS=0
FAIL=0
CH0=""
CH1=""
CH0_ADDR=""
CH1_ADDR=""

if ((EUID == 0)); then
	SUDO=()
else
	SUDO=(sudo -n)
	if ! "${SUDO[@]}" true 2>/dev/null; then
		echo "Run as root or configure non-interactive sudo." >&2
		exit 2
	fi
fi

MODULE_PATH=${MODULE_PATH:-$(modinfo -n i2c-imc-skylake)}
if [[ ! -r "$MODULE_PATH" ]]; then
	echo "Module not found: $MODULE_PATH" >&2
	exit 2
fi

_ok()
{
	echo "PASS: $*"
	((PASS++)) || true
}

_fail()
{
	echo "FAIL: $*"
	((FAIL++)) || true
}

_module_loaded()
{
	lsmod | awk '$1 == "i2c_imc_skylake" { found = 1 } END { exit !found }'
}

_bus()
{
	local channel=$1

	i2cdetect -l 2>/dev/null | awk -v channel="$channel" '
		tolower($0) ~ /imc.*channel/ && $0 ~ "channel " channel {
			sub(/^i2c-/, "", $1)
			print $1
			exit
		}'
}

_find_pci_device()
{
	local device path vendor

	for path in /sys/bus/pci/devices/*; do
		[[ -r "$path/vendor" && -r "$path/device" ]] || continue
		read -r vendor < "$path/vendor"
		read -r device < "$path/device"
		if [[ "$vendor" == "0x8086" && "$device" == "0x2085" ]]; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	return 1
}

_refresh_buses()
{
	CH0=$(_bus 0)
	CH1=$(_bus 1)
}

_scan_spd()
{
	local bus=$1 result_var=$2
	local address address_hex device readable="" value
	local found=false

	echo "--- SPD scan bus $bus (read-only BYTE_DATA) ---"
	for address in {80..87}; do
		printf -v address_hex '0x%02x' "$address"
		printf -v device '%d-%04x' "$bus" "$address"
		if [[ -L "/sys/bus/i2c/devices/$device/driver" ]]; then
			echo "  $address_hex present (bound to $(basename "$(readlink "/sys/bus/i2c/devices/$device/driver")"))"
			found=true
			continue
		fi
		if value=$("${SUDO[@]}" i2cget -y "$bus" "$address_hex" 0x00 2>/dev/null); then
			echo "  $address_hex present (reg0=$value)"
			found=true
			readable=${readable:-$address_hex}
		fi
	done

	printf -v "$result_var" '%s' "$readable"
	$found
}

_word_test()
{
	local bus=$1 address=$2
	local byte0 byte1 expected word

	if ! byte0=$("${SUDO[@]}" i2cget -y "$bus" "$address" 0x00 2>/dev/null) ||
	   ! byte1=$("${SUDO[@]}" i2cget -y "$bus" "$address" 0x01 2>/dev/null) ||
	   ! word=$("${SUDO[@]}" i2cget -y "$bus" "$address" 0x00 w 2>/dev/null); then
		return 1
	fi

	expected=$((byte0 | (byte1 << 8)))
	((word == expected))
}

_nack_test()
{
	local bus=$1
	local trace

	command -v strace >/dev/null || return 1
	trace=$("${SUDO[@]}" strace -qq -f -e trace=ioctl \
		i2cget -y "$bus" 0x77 0x00 2>&1 || true)
	grep -q '= -1 ENXIO' <<< "$trace"
}

_stress_reader()
{
	local bus=$1 address=$2
	local iteration

	for iteration in {1..100}; do
		"${SUDO[@]}" i2cget -y "$bus" "$address" 0x02 >/dev/null 2>&1 || return 1
	done
}

_load_unsafe()
{
	"${SUDO[@]}" insmod "$MODULE_PATH" allow_unsafe_access=1
}

DMESG_START=$("${SUDO[@]}" dmesg | wc -l)
"${SUDO[@]}" modprobe i2c-dev
_module_loaded && "${SUDO[@]}" rmmod i2c-imc-skylake
_load_unsafe

echo "=== adapter discovery ==="
_refresh_buses
[[ -n "$CH0" ]] && _ok "ch0 adapter at i2c-$CH0" || _fail "ch0 adapter not found"
[[ -n "$CH1" ]] && _ok "ch1 adapter at i2c-$CH1" || _fail "ch1 adapter not found"

if [[ -n "$CH0" ]]; then
	_scan_spd "$CH0" CH0_ADDR && _ok "SPD device present on ch0" || _fail "no SPD device on ch0"
fi
if [[ -n "$CH1" ]]; then
	_scan_spd "$CH1" CH1_ADDR && _ok "SPD device present on ch1" || _fail "no SPD device on ch1"
fi

echo "=== transfer semantics ==="
if [[ -n "$CH0_ADDR" ]]; then
	_word_test "$CH0" "$CH0_ADDR" && _ok "WORD_DATA byte order on ch0" || _fail "WORD_DATA test on ch0"
fi
if [[ -n "$CH1_ADDR" ]]; then
	_word_test "$CH1" "$CH1_ADDR" && _ok "WORD_DATA byte order on ch1" || _fail "WORD_DATA test on ch1"

fi
if [[ -n "$CH0" ]]; then
	_nack_test "$CH0" && _ok "absent-device ENXIO on ch0" || _fail "expected ENXIO at address 0x77 on ch0"
fi
if [[ -n "$CH1" ]]; then
	_nack_test "$CH1" && _ok "absent-device ENXIO on ch1" || _fail "expected ENXIO at address 0x77 on ch1"
fi

if [[ -n "$CH0_ADDR" && -n "$CH1_ADDR" ]]; then
	_stress_reader "$CH0" "$CH0_ADDR" &
	pid0=$!
	_stress_reader "$CH1" "$CH1_ADDR" &
	pid1=$!
	stress_ok=true
	wait "$pid0" || stress_ok=false
	wait "$pid1" || stress_ok=false
	$stress_ok && _ok "concurrent 100-read stress on both channels" || _fail "concurrent read stress"
fi

echo "=== safe default and targeted udev event ==="
PCI_DEVICE=$(_find_pci_device) || {
	_fail "PCI device 8086:2085 not found"
	PCI_DEVICE=""
}
if [[ -n "$PCI_DEVICE" ]]; then
	"${SUDO[@]}" rmmod i2c-imc-skylake
	"${SUDO[@]}" insmod "$MODULE_PATH"
	_refresh_buses
	if [[ -z "$CH0" && -z "$CH1" ]]; then
		_ok "default-off gate rejected bind without opt-in"
	else
		_fail "driver bound without allow_unsafe_access=1"
	fi
	_module_loaded && "${SUDO[@]}" rmmod i2c-imc-skylake

	if "${SUDO[@]}" udevadm trigger --action=add "$PCI_DEVICE" &&
	   "${SUDO[@]}" udevadm settle --timeout=5; then
		_ok "targeted PCI udev event completed"
	else
		_fail "targeted PCI udev event failed"
	fi
	_module_loaded && "${SUDO[@]}" rmmod i2c-imc-skylake
	_load_unsafe
fi

echo "=== load/unload x20 ==="
for iteration in {1..20}; do
	"${SUDO[@]}" rmmod i2c-imc-skylake
	_load_unsafe
	echo "  cycle $iteration OK"
done
_ok "20 load/unload cycles completed"

echo "=== kernel messages produced by this test ==="
NEW_DMESG=$("${SUDO[@]}" dmesg | tail -n "+$((DMESG_START + 1))")
RELEVANT_DMESG=$(grep -Ei 'i2c-imc-skylake [0-9a-f]{4}:|BUG:|WARNING:|Oops:|KASAN:|lockdep' <<< "$NEW_DMESG" || true)
printf '%s\n' "$RELEVANT_DMESG"
if grep -Eiq 'BUG:|WARNING:|Oops:|KASAN:|lockdep' <<< "$NEW_DMESG"; then
	_fail "kernel warning/oops detected"
else
	_ok "no kernel warning/oops detected"
fi

# The driver compares the command registers before and after every transfer.
# A hit here means firmware, a BMC or CLTT is driving the same engine, which
# invalidates every other result in this run.
if grep -q 'another master is using the engine' <<< "$NEW_DMESG"; then
	_fail "foreign master detected on the engine; do not use this system"
else
	_ok "no foreign master detected during the test"
fi

# Likewise for a command the engine never accepted: that path exists because
# the done bits are latched and must not be mistaken for a fresh completion.
if grep -q 'command not accepted' <<< "$NEW_DMESG"; then
	_fail "engine did not accept a command; config access path is unreliable"
else
	_ok "every command was accepted by the engine"
fi

echo "=== result: $PASS passed, $FAIL failed ==="
((FAIL == 0))
