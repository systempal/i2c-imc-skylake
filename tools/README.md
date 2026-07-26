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
