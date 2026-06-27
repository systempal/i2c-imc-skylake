# Plan — v3 Submission: massimizzare probabilità di accept

## Obiettivo

Inviare una v3 della patch `i2c: imc-skylake` a `linux-i2c` che massimizzi
le probabilità di merge da parte di Wolfram Sang (maintainer i2c).

## Stato attuale

- **v2** inviata il 20 Giu 2026 (message-ID `20260620144131.415559-1`)
- **v2** sotto review, nessun feedback ricevuto al momento
- **Driver**: `i2c-imc-skylake.c` (436 righe), checkpatch clean, build OK
- **Branch di lavoro**: `feat/word-data-and-pec` (da main)

---

## Fase 1 — Feature: WORD_DATA (priorità alta)

### Motivazione
I sensori termici DIMM (TSOD) usano `I2C_SMBUS_WORD_DATA` per leggere
temperatura in formato 16-bit. Senza WORD_DATA, `lm-sensors` non può
leggere i TSOD — questo è il caso d'uso principale del driver per
lm-sensors. Il maintainer probabilmente lo richiederà.

### Implementazione
- Aggiungere `WORD_BIT` (`BIT(17)`) al FRAME per word transfers
- Per write: latch 2 byte in CTRL (bits[23:16] = byte alto, bits[31:24] = byte basso, o viceversa — verificare con PawnIO)
- Per read: leggere 2 byte da CTRL (low word)
- Aggiungere `I2C_SMBUS_WORD_DATA` a `imc_smbus_xfer()` e `imc_func()`
- Verificare byte order con PawnIO: `((dataReg & 0xFF00) >> 8) | ((dataReg & 0x00FF) << 8)`

### File da modificare
- `i2c-imc-skylake.c`: `imc_smbus_xfer()`, `imc_func()`, nuove `imc_read_word()` / `imc_write_word()`

### Test
- Leggere TSOD (indirizzo 0x18-0x1F tipico) con `i2cget -y N 0x18 w` su entrambi i canali
- Verificare che `i2cdetect` non si rompa

---

## Fase 2 — Cover letter v3 (priorità alta)

### Punti da aggiungere/aggiornare rispetto a v2

1. **Rename explanation**: v2 era `i2c-imc-x299`, v3 è `i2c-imc-skylake`
   - Il driver copre Skylake-X / Cascade Lake-X, non solo X299
   - X299 è il chipset, l'iMC SMBus è nel CPU

2. **Independent validation**: il register layout è confermato da
   implementazioni indipendenti:
   - PawnIO.Modules (`SmbusIntelSkylakeIMC.p`, Windows userspace, Feb 2026)
   - HWiNFO / SIV (tool commerciali Windows)
   - Entrambi usano gli stessi registri (0x9C/0xA8/0xB4, stride 4, GO bit19)

3. **WORD_DATA**: ora supportato — TSOD leggibili da lm-sensors

4. **BYTE non implementato**: l'engine richiede sempre un register offset;
   I2C_SMBUS_BYTE (senza offset) non è nativo e la sua emulazione con
   offset fittizio non è appropriata per upstream. `i2cdetect` richiede
   `-r` flag (read byte data probe). `ee1004` (driver SPD kernel) funziona
   già con solo BYTE_DATA.

5. **Changelog v2→v3**:
   ```
   Changes since v2:
   - Rename driver from i2c-imc-x299 to i2c-imc-skylake
   - Fix iMC SMBus attribution: engine is in the CPU (Skylake-X), not
     the X299 chipset
   - Add I2C_SMBUS_WORD_DATA support (WORD_BIT bit17) for TSOD reads
   - Update adapter name: "iMC SMBus Skylake-X channel N"
   ```

5. **CC list**: `linux-i2c@vger.kernel.org`, `wsa@kernel.org`,
   `linux-kernel@vger.kernel.org`

### File da modificare
- `docs/submission/cover-letter.txt`

---

## Fase 4 — Review interna pre-submission (priorità alta)

### Checklist
- [ ] `make checkpatch` — 0 errors, 0 warnings, 0 checks
- [ ] `make` — build clean
- [ ] HW test: `i2cdetect -l` mostra 2 canali "iMC SMBus Skylake-X"
- [ ] HW test: SPD readable (0x50, 0x52) con BYTE_DATA
- [ ] HW test: TSOD readable con WORD_DATA (se implementato)
- [ ] HW test: ENE LED controller (0x27) risponde
- [ ] HW test: `i2cdetect -y N` funziona (con BYTE support)
- [ ] HW test: 20× modprobe/rmmod — no oops, no leak
- [ ] HW test: udev autoload funziona
- [ ] `git format-patch` genera patch pulita
- [ ] `checkpatch.pl --strict` sulla patch generata (non solo sul file)
- [ ] Cover letter con changelog v2→v3
- [ ] Signed-off-by presente

---

## Fase 5 — Generazione e invio (priorità alta)

### Steps
1. Clonare `git://git.kernel.org/pub/scm/linux/kernel/git/wsa/linux.git`
2. Copiare `i2c-imc-skylake.c` in `drivers/i2c/busses/`
3. Aggiungere entry Kconfig (da `docs/submission/Kconfig.kernel`)
4. Aggiungere riga Makefile: `obj-$(CONFIG_I2C_IMC_SKYLAKE) += i2c-imc-skylake.o`
5. Aggiungere entry MAINTAINERS
6. `git commit -s -m "i2c: imc-skylake: add driver for Intel Skylake-X iMC SMBus engine"`
7. `git format-patch -1 -o patches/ --cover-letter`
8. Editare `patches/0000-cover-letter.patch` con il contenuto di `docs/submission/cover-letter.txt`
9. `perl scripts/checkpatch.pl --strict patches/0001-*.patch` — deve essere 0/0
10. `git send-email --to=linux-i2c@vger.kernel.org --cc=wsa@kernel.org --cc=linux-kernel@vger.kernel.org patches/`

---

## Fase 6 — Considerazioni per massimizzare accept

### Cosa il maintainer guarda
1. **Correttezza tecnica** — register layout confermato da RE indipendente ✅
2. **Stile kernel** — checkpatch clean ✅
3. **devm / lifecycle** — già corretto ✅
4. **Nessun parametro di modulo non standard** — `settle_us` è generico ✅
5. **Nessun safety flag** — X299 HEDT non ha BMC/CLTT ✅
6. **Copertura funzionale** — WORD_DATA per TSOD è attesa
7. **Coerenza naming** — `i2c-imc-skylake` + `iMC SMBus Skylake-X` ✅
8. **Cover letter chiara** — spiega ECAM, prior art, rename

### Cosa evitare
- ❌ Parametri di modulo per bus/dev/fn (già rimosso)
- ❌ `I2C_CLASS_HWMON` (deprecato)
- ❌ `trace` module parameter (già rimosso)
- ❌ Riferimenti a brand specifici (Kingston, ENE) nel codice
- ❌ `Co-Authored-By: Claude` (già rimosso)
- ❌ `.remove` vuota (già rimossa)

### Rischi residui
- **Arbitration**: X299 HEDT non ha BMC, ma il maintainer potrebbe chiedere
  conferma. La cover letter spiega perché non serve.
- **ECAM manuale**: il maintainer potrebbe obiettare sul walk manuale di MCFG.
  Risposta: `pci_mmcfg_*` non è esportato ai moduli, non c'è alternativa.
- **No request_mem_region**: spiegato nel commento (MMCONFIG è già claimato)
- **Tempo dalla v2**: se la v2 non ha feedback, aspettare almeno 1-2 settimane
  prima di inviare v3 (etichetta kernel: "resend after 2 weeks if no response")

---

## Priorità di implementazione

| Fase | Priorità | Sforzo | Impatto su accept |
|---|---|---|---|
| 1. WORD_DATA | Alta | Medio | Alto — TSOD è caso d'uso principale |
| 2. Cover letter v3 | Alta | Basso | Alto — prima impressione |
| 3. Review interna | Alta | Basso | Essenziale |
| 4. Generazione/invio | Alta | Basso | Essenziale |
| 5. Considerazioni | — | — | Riferimento |

## Branch

- `feat/word-data-and-pec` — implementazione feature
- `main` — merge dopo test HW
- `compat` — mantenuto per compatibilità tool vecchi