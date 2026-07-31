# Piano: quiescing dell'engine a shutdown (`.shutdown`)

**Contesto** (2026-07-31): ws1-mint ha un hang intermittente di poweroff (LED
acceso, tutto il resto spento), isolato al tratto `machine_power_off()` →
ACPI `_S5`. Evidenza: reboot mai appesi (5/5, anche dopo sessioni di 32 h),
Windows con Fast Startup disattivato mai appeso, journal degli shutdown appesi
byte-identici a quelli puliti, netconsole muto dopo `mlx4_shutdown`. Ipotesi di
lavoro: l'handler SMI del BIOS (ASUS TUF X299 MARK 1, BIOS 4201) al trap di S5
trova l'engine SMBus dell'iMC in stato "di sessione" e si inchioda. L'engine è
usato tutta la sessione da furyd (ENE 0x27 su entrambi i canali) e dai tool di
sviluppo.

**Questo piano è hygiene corretta a prescindere dall'esito**: il driver
condivide l'engine con il firmware (vedi commento in testa al sorgente) e oggi
non lo riconsegna mai. La conferma causale resta affidata alla console seriale
(`console=ttyS0`), piano separato.

Ordine: eseguire prima questo piano, poi il gemello in
`~/_Workspace/furyrs/docs/plans/shutdown-smbus-hygiene.md`.

---

## T1 — Snapshot pristino dei registri a probe

**GOAL**: salvare, una volta sola al bind, le CMD word di entrambi i canali
com'erano prima di qualunque transfer del driver: sono lo stato che il
firmware ha lasciato al boot e che deve ritrovare a `_S5`.

**ANCHORS**: `i2c-imc-skylake.c` — `struct imc_smbus` (r. 162),
`imc_pci_probe()` (r. 675, dopo `imc_check_firmware_polling` e prima della
registrazione degli adapter).

**CHANGE**: due nuovi campi (uno per canale) in `struct imc_smbus`, letti in
probe con l'accessor esistente. Fallimento di lettura (`io_err`) = fallire il
probe: uno snapshot inattendibile rende il quiescing dannoso.

**CONSTRAINTS**: nessun cambiamento al path dei transfer; niente scritture in
probe.

**VERIFY**: `grep -n "pristine\|boot_cmd" i2c-imc-skylake.c` mostra campo +
unico punto di scrittura in probe; smoke test invariato.

## T2 — Callback `.shutdown`

**GOAL**: a shutdown/kexec: nessun transfer in volo, engine idle, CMD word
pristine ripristinate (mascherate `~GO_BIT`). Best effort, mai bloccante oltre
i timeout esistenti, mai panic.

**ANCHORS**: `struct pci_driver imc_driver` (r. 770), `imc_suspend()` (r. 637,
modello per marcare gli adapter suspended), `mutex` `s->lock` (r. 165),
`imc_wait_engine_idle()` (r. 218), `imc_restore_xfer()` (r. 366, modello per
la scrittura mascherata).

**CHANGE**: nuova `imc_pci_shutdown(struct pci_dev *)` registrata in
`imc_driver`. Sequenza-invariante: guard su `drvdata` NULL (probe mai riuscito)
→ marca entrambi gli adapter suspended (blocca nuovi transfer) → `mutex_lock`
(drena l'eventuale transfer in volo, bounded ~750 ms worst case) → attesa
engine idle → ripristino word pristine → unlock. Errori di config space:
ignorati (a shutdown non c'è nessuno a cui riportarli), ma niente scritture se
la lettura dello snapshot in probe era fallita (non accade: T1 fallisce il
probe).

**CONSTRAINTS**: nessuna allocazione, nessun sleep oltre i poll esistenti;
callback idempotente; vale anche per kexec (stesso callback, stessa
correttezza).

**VERIFY**: build DKMS pulita per il kernel corrente;
`grep -n "\.shutdown" i2c-imc-skylake.c` → registrata; con `dev_dbg` attivo un
reboot mostra la callback eseguita (`journalctl -k -b -1` dopo reboot con
`dyndbg` sul modulo).

## T3 — Snapshot rinfrescato al resume

**GOAL**: dopo S3 il firmware può aver usato l'engine (osservato: read SPD in
memory training al resume) → lo snapshot di probe è potenzialmente stantio.

**ANCHORS**: `imc_resume()` (r. 648).

**CHANGE**: se il re-check `imc_check_firmware_polling` passa, ri-leggere le
CMD word e aggiornare lo snapshot prima di rimarcare gli adapter resumed. Se
la lettura fallisce: adapter restano suspended (comportamento attuale sul
fallimento del re-check).

**VERIFY**: suspend/resume manuale (`test-suspend.sh`) invariato; snapshot
aggiornato osservabile via `dev_dbg`.

## T4 — Commento di lifetime da correggere

**GOAL**: il blocco "register state deliberately left as-is on unbind"
(r. 762-769) resta vero per l'unbind a OS vivo ma diventa falso come rationale
globale: a shutdown il prossimo utente è il firmware.

**CHANGE**: riscrivere il commento distinguendo unbind (as-is, corretto) da
shutdown (handback pristino, T2). È materiale utile anche per il cover letter
v3: engine firmware-shared + caso reale di wedge S5 sotto indagine.

**VERIFY**: il commento nomina entrambe le semantiche; `checkpatch.pl --strict`
pulito sul diff complessivo.

## T5 — Versioning

**CHANGE**: bump `VERSION` e `dkms.conf` (1.0.4); nota in `TODO.md` che il
quiescing è in test come possibile fix dell'hang S5 (link a questo file).

**VERIFY**: `dkms status` mostra la nuova versione installata per il kernel
corrente; `test-smoke.sh` verde end-to-end.

---

**Fuori scope qui**: qualunque modifica a furyd (piano gemello), la console
seriale, i tool `probe-cf8-*` (restano strumenti di indagine, non li tocca
questo piano).
