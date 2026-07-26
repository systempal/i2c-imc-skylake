#!/usr/bin/env bash
#
# WRITES TO HARDWARE. Issues an SMBus read through the interface Intel
# documents, rather than the one this driver currently uses.
#
# Intel Xeon Processor Scalable Family datasheet vol. 2 (ref. 614073) chapter 3
# puts the iMC SMBus interface on device 10 and 12, function 0:
#
#   SMB_STAT_[0:1]   0xe80 0xe90   b31 RDO, b30 WOD, b29 SBE, b28 BUSY,
#                                  b27:24 tsod_sa, b15:0 RDATA
#   SMBCMD_[0:1]     0xe84 0xe94   b31 CMD_TRIGGER, b30 PNTR_SEL,
#                                  b29 WORD_ACCESS, b28:27 rw, b26:24 SA,
#                                  b23:16 BA, b15:0 WDATA
#   SMBCNTL_[0:1]    0xe88 0xe98   b31:28 DTI (0xa EEPROM, 0x3 TSOD),
#                                  b27 CKOVRD, b26 DIS_WRT, b10 SOFT_RST,
#                                  b9 start_tsod_poll, b8 TSOD_POLL_EN,
#                                  b7:0 TSOD_PRESENT
#
# The driver instead uses PCU function 5 at 0x9c-0xb8, which that document does
# not describe (it covers device 30 functions 0 and 2 only).  This script reads
# a known SPD byte through the documented path so the two can be compared.
#
# Read transaction only, against an EEPROM that is certainly present.  SMBCMD is
# restored on every exit path.  SMBCNTL is not written at all.
#
set -euo pipefail

# shellcheck source=tools/common.sh
source "$(dirname "$(readlink -f "$0")")/common.sh"

SMB_STAT=(0xe80 0xe90)
SMB_CMD=(0xe84 0xe94)
SMB_CNTL=(0xe88 0xe98)

CMD_TRIGGER=$((1 << 31))
STAT_RDO=$((1 << 31))
STAT_WOD=$((1 << 30))
STAT_SBE=$((1 << 29))
STAT_BUSY=$((1 << 28))
CNTL_TSOD_POLL_EN=$((1 << 8))

SA=0		# slave address low bits; DTI 0xa | SA 0 selects 0x50
BA=0x02		# SPD byte 2, DDR4 type code, expected 0x0c
CONFIRMED=false

while (($#)); do
	case $1 in
	--i-understand) CONFIRMED=true; shift ;;
	--sa) SA=$2; shift 2 ;;
	--ba) BA=$2; shift 2 ;;
	-h|--help)
		sed -n '3,26p' "$0"
		echo "usage: $0 --i-understand [--sa N] [--ba 0xNN]"
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done

$CONFIRMED || {
	echo "Issues an SMBus read from userspace. Re-run with --i-understand." >&2
	exit 2
}

require_root
require_cmd lspci setpci awk
driver_is_loaded && die "unload i2c-imc-skylake first"

mapfile -t IMCS < <(lspci -Dn -d 8086:2040 | awk '{print $1}')
((${#IMCS[@]})) || die "no iMC channel device (8086:2040) found"

probe_one()
{
	local bdf=$1 ch=$2
	local stat=${SMB_STAT[ch]} cmd=${SMB_CMD[ch]} cntl=${SMB_CNTL[ch]}
	local cntl_val stat_val cmd_saved command i data

	cntl_val=$(read_reg "$bdf" "$cntl")
	stat_val=$(read_reg "$bdf" "$stat")
	cmd_saved=$(read_reg "$bdf" "$cmd")

	printf '  SMBCNTL=%s  SMB_STAT=%s  SMBCMD=%s\n' \
		"$cntl_val" "$stat_val" "$cmd_saved"

	if ((cntl_val & CNTL_TSOD_POLL_EN)); then
		echo "  SKIP: TSOD_POLL_EN is set, firmware owns this channel"
		return 0
	fi
	if ((stat_val & STAT_BUSY)); then
		echo "  SKIP: SMB_BUSY is set"
		return 0
	fi

	# byte read: TRIGGER, PNTR_SEL=0, WORD=0, rw=00, SA, BA
	command=$((CMD_TRIGGER | (SA << 24) | (BA << 16)))
	printf '  issuing SMBCMD=0x%08x (read SA=%d BA=%s)\n' "$command" "$SA" "$BA"
	setpci -s "$bdf" "$cmd.L=$(printf '%08x' "$command")"

	for i in $(seq 1 50); do
		stat_val=$(read_reg "$bdf" "$stat")
		((stat_val & STAT_BUSY)) || break
		sleep 0.005
	done

	setpci -s "$bdf" "$cmd.L=$(printf '%08x' "$cmd_saved")"

	data=$((stat_val & 0xff))
	printf '  SMB_STAT=%s  RDO=%d WOD=%d SBE=%d BUSY=%d  RDATA=0x%02x\n' \
		"$stat_val" \
		"$(((stat_val & STAT_RDO) != 0))" \
		"$(((stat_val & STAT_WOD) != 0))" \
		"$(((stat_val & STAT_SBE) != 0))" \
		"$(((stat_val & STAT_BUSY) != 0))" \
		"$data"

	if ((stat_val & STAT_SBE)); then
		echo "  -> SBE: the addressed device did not answer on this channel"
	elif ((stat_val & STAT_RDO)); then
		printf '  -> READ OK, data 0x%02x\n' "$data"
		if [[ "$BA" == "0x02" ]] && ((data == 0x0c)); then
			echo "     matches the DDR4 type code, so the documented"
			echo "     interface reaches the same devices."
		fi
	else
		echo "  -> no completion: the interface did not act on the command"
	fi
}

for bdf in "${IMCS[@]}"; do
	for ch in 0 1; do
		echo "=== $bdf channel $ch ==="
		probe_one "$bdf" "$ch"
		echo
	done
done
