# Hardware measurements still owed to the submission

Three scripts, meant to be run by hand on an X299 (or Cascade Lake-X) system
with the PCU function `8086:2085`. None of them is run by CI and none is run by
`make test`.

Output of all three belongs in the cover letter or in a reply on the list, as
raw numbers. Do not paraphrase them.

| Script | Answers | Writes to hardware |
| --- | --- | --- |
| `watch-engine.sh` | Is firmware using the engine on this system? | no |
| `dump-pcu-config.sh` | Which PCU registers move on their own? Is there a TSOD polling control? | no |
| `probe-cf8-write.sh` | Is the CF8/CFC write really dropped, and does it raise an SMI? | **yes**, requires `--i-understand` |

## 1. `watch-engine.sh` — foreign activity (read-only)

Samples the six per-channel registers and reports every change that this
system's Linux side did not cause. Run it with the driver **unloaded**, so that
anything observed is firmware.

```bash
sudo ./tools/watch-engine.sh --seconds 3600
```

What the cover letter needs: a run of at least one hour, ideally across a
suspend/resume cycle, with the observed change count. A non-zero count on a
system means the driver must not be loaded there, and is itself a result worth
reporting.

## 2. `dump-pcu-config.sh` — register survey (read-only)

Dumps the function's 4 KB config space twice and diffs them, then prints the
neighbourhood of the offsets that matter.

```bash
sudo ./tools/dump-pcu-config.sh --settle 10
```

This is the search for the open item F2: the Broadwell-E iMC driver stops the
PCU's TSOD polling for the duration of a transfer by writing 0 to `TSODCNTL`
at offset `0xe0` of its PCU function, waiting 10 ms for in-flight transactions
to drain, and restoring the value afterwards. No equivalent register has been
identified on `8086:2085`. A field that changes on its own with a fixed cadence
is the first candidate.

## 3. `probe-cf8-write.sh` — the dropped write (WRITES TO HARDWARE)

This is the only script that writes. It changes the register/offset field of a
command register while the GO bit is clear, which does not start an SMBus
transaction, then reads it back and reports whether the write stuck. It also
reads `MSR_SMI_COUNT` (0x34) on every CPU before and after.

```bash
sudo ./tools/probe-cf8-write.sh --i-understand
```

Two results matter:

* the value does **not** read back → the claim "CF8/CFC writes to this function
  do not take effect" is confirmed on the tested board;
* the SMI delta is **0** → the behaviour is not System Management Mode, and the
  driver's comments and the cover letter must not say it is.

Requirements: `msr-tools` (`rdmsr`), `pciutils` (`setpci`, `lspci`), and the
`msr` module (`modprobe msr`).

## 4. `probe-cf8-transaction.sh` — does CF8/CFC start a transfer? (WRITES TO HARDWARE)

Follow-up to §3. `probe-cf8-write.sh` shows whether the register accepts a
value; this shows whether the engine acts on it, by setting the GO bit for a
read of an unpopulated address and watching STATUS.

```bash
sudo ./tools/probe-cf8-transaction.sh --i-understand
```

It does start one. That result retired the plan to reach these registers
through ECAM with a PCI-core change, and the driver uses the ordinary config
accessors.

## 5. `probe-imc-documented.sh` — the interface Intel documents (WRITES TO HARDWARE)

Issues a read through `SMB_STAT`/`SMBCMD`/`SMBCNTL` on the iMC channel
functions (`8086:2040`), the interface the datasheet describes, rather than the
PCU registers this driver uses.

```bash
sudo ./tools/probe-imc-documented.sh --i-understand
```

On the development board it reports `RDO=1, SBE=0, RDATA=0x00` identically for
a populated 0x50, a populated 0x52 and an absent 0x57: it completes but cannot
tell a populated slot from an empty one, so it is not reaching this bus.

## 6. `probe-pntr-sel.sh` — find the address-only bit (read-only on the bus)

Finds the command-word bit that suppresses the register byte, which is what
SMBus Receive Byte and Send Byte need.

```bash
sudo ./tools/probe-pntr-sel.sh --i-understand --channel 1
```

Not a blind sweep. An EEPROM auto-increments its pointer after a read, so
priming the pointer with an ordinary read and then repeating it with the
candidate bit set has a predicted answer: the *next* byte, not the one named.
The script checks that prediction at two different offsets and then walks eight
consecutive reads, which an ordinary dump must reproduce exactly.

The answer on this engine is bit 18, matching the position of `PNTR_SEL`
relative to `WORD_ACCESS` in the documented `SMBCMD` layout. Reads only, and
never to the page-select addresses, so the DDR4 page latch does not move.

## 7. `probe-send-byte.sh` — the write half (WRITES TO HARDWARE)

Confirms the same bit produces a Send Byte, against the page-select addresses
`0x36`/`0x37`. Those hold a latch and store no data, so the only thing a write
there can do is choose which half of the SPD is visible — and that choice is
itself the readout, since byte 0x00 is the JEDEC `0x23` on page 0 and something
else on page 1. Nothing is written to `0x50`-`0x57`.

```bash
sudo ./tools/probe-send-byte.sh --i-understand --channel 0 --restore
```

`--restore` is the safe first run: it targets a channel already stuck on page 1
and selects page 0, so a working Send Byte repairs that channel and a broken one
leaves it exactly as found. There is no outcome worse than the starting state.
`--flip` does the full round trip on a healthy channel, after `--restore` has
shown the encoding works.

A channel found on page 1 is not a fault of this driver: `ee1004`, and
OpenRGB's `DDR4DirectAccessor::set_page()`, both select a page and leave it
selected.
