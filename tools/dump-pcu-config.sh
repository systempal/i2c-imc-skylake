#!/usr/bin/env bash
# Dump the PCU function's config space twice and report what moved on its own.
# Read-only. Used to look for a TSOD polling control register (see tools/README.md).
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

SETTLE=10
OUTDIR=${OUTDIR:-.}

while (($#)); do
	case $1 in
	--settle) SETTLE=$2; shift 2 ;;
	--outdir) OUTDIR=$2; shift 2 ;;
	-h|--help)
		echo "usage: $0 [--settle SECONDS] [--outdir DIR]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

require_root
require_cmd lspci awk

BDF=$(find_pcu)
first=$(mktemp)
second=$(mktemp)
trap 'rm -f "$first" "$second"' EXIT

echo "device: $BDF"
if driver_is_loaded; then
	echo "warning: i2c-imc-skylake is loaded; unload it first for a clean survey." >&2
fi

lspci -s "$BDF" -xxxx > "$first"
echo "first dump taken, waiting ${SETTLE}s..."
sleep "$SETTLE"
lspci -s "$BDF" -xxxx > "$second"

stamp=$(date +%Y%m%d-%H%M%S)
cp "$second" "$OUTDIR/pcu-config-$stamp.txt"
echo "full dump saved to $OUTDIR/pcu-config-$stamp.txt"
echo

echo "=== bytes that changed on their own over ${SETTLE}s ==="
if diff -u "$first" "$second" | grep -E '^[+-][0-9a-f]{3}:' ; then
	echo
	echo "A field with a steady cadence is the first candidate for a TSOD"
	echo "polling control. Compare with the Broadwell-E driver's TSODCNTL (0xe0)."
else
	echo "(none: the whole config space was stable)"
fi
echo

echo "=== engine registers ==="
snapshot_regs "$BDF"
echo

# lspci -xxxx prints two-digit offsets for the first 256 bytes and three or
# more digits above that, so anchor on the short form here.
echo "=== neighbourhood of the Broadwell TSODCNTL offset (0xe0) ==="
awk '/^[cdef]0:/ { print }' "$second"
echo
echo "=== the driver's register window (0x90-0xbf) ==="
awk '/^[9ab]0:/ { print }' "$second"
