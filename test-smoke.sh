#!/usr/bin/env bash
# Smoke test for i2c-imc-skylake (pci_driver, no bus/dev/fn params).
# Run after: make install  OR  make reload
# Requires: root, i2c-tools (i2cdetect), module already loaded.
set -euo pipefail

PASS=0
FAIL=0

_ok()   { echo "PASS: $*"; ((PASS++)) || true; }
_fail() { echo "FAIL: $*"; ((FAIL++)) || true; }

echo "=== adapter list ==="
i2cdetect -l | grep -i imc || _fail "no imc adapters visible"

_bus() {
	i2cdetect -l 2>/dev/null | grep -i "imc.*channel $1" | awk '{print $1}' | tr -d 'i2c-'
}

CH0=$(_bus 0)
CH1=$(_bus 1)

if [ -n "$CH0" ]; then
	_ok "ch0 adapter at i2c-$CH0"
else
	_fail "ch0 adapter not found"
fi

if [ -n "$CH1" ]; then
	_ok "ch1 adapter at i2c-$CH1"
else
	_fail "ch1 adapter not found"
fi

# The engine has no QUICK/BYTE primitive, so `i2cdetect` cannot scan the bus
# ("Bus doesn't support detection commands"). Probe SPD addresses directly with
# a byte-data read of register 0x00 instead.
_scan_spd() {
	local bus=$1 found=""
	echo "--- SPD scan bus $bus (byte-data read of reg 0x00) ---"
	for a in 0x50 0x51 0x52 0x53 0x54 0x55 0x56 0x57; do
		if v=$(i2cget -y "$bus" "$a" 0x00 2>/dev/null); then
			echo "  $a present (reg0=$v)"
			found="$a"
		fi
	done
	[ -n "$found" ]
}

if [ -n "$CH0" ]; then
	echo ""
	if _scan_spd "$CH0"; then
		_ok "SPD device present on ch0"
	else
		_fail "no SPD device on ch0"
	fi
fi

if [ -n "$CH1" ]; then
	echo ""
	_scan_spd "$CH1" && _ok "SPD device present on ch1" || true
fi

echo ""
echo "=== udev autoload ==="
sudo rmmod i2c-imc-skylake
sleep 1
sudo udevadm trigger --subsystem-match=pci --action=add
sleep 2
if lsmod | grep i2c_imc_skylake >/dev/null; then
	_ok "udev autoload"
else
	_fail "udev did not reload module — check /etc/modules-load.d/ or udev rules"
fi

echo ""
echo "=== load/unload x5 (leak/oops) ==="
for i in $(seq 1 5); do
	sudo rmmod i2c-imc-skylake
	sudo modprobe i2c-imc-skylake
	echo "  cycle $i OK"
done
_ok "5 load/unload cycles completed"

echo ""
echo "=== dmesg tail ==="
dmesg | tail -20

echo ""
echo "=== result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
