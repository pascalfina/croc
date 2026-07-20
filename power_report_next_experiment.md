# Den Adresseffekt sauber isolieren

**Ergänzung zu `power_report_20260720.md` · 20. Juli 2026**

---

## Das Problem mit der jetzigen Messung

Baseline und Burst sind zwei getrennt synthetisierte und getrennt platzierte Chips.
Beim Vergleich vermischen sich mindestens drei Effekte:

1. die Adresskompression selbst (das, was gemessen werden soll)
2. die zusätzliche Burst-Hardware (Kompressor, `burst_endpoint_rw`, FSMs)
3. Place-&-Route-Rauschen — andere Platzierung, andere Leitungslängen, andere Parasitics

Effekt 3 ist der ärgerlichste, weil seine Größe unbekannt ist. Er könnte einen Teil der
gemessenen +9.4 % erklären, und niemand kann sagen wie viel. Ein Gutachter wird genau
das fragen.

---

## Die Beobachtung, die den Ausweg öffnet

Aus `burst_endpoint_rw.sv:85`:

```systemverilog
R_IDLE: begin
    if (rd_req_i.hdr_valid) begin
        read_addr_d = rd_req_i.hdr.start_addr;   // <-- aus dem Burst-Header
```

und `burst_endpoint_rw.sv:97`:

```systemverilog
R_READ: begin
    if (sram_gnt_i && rd_grant) begin
        read_addr_d = read_addr_q + 4;           // <-- lokal weitergezählt
```

**Das Endpoint liest die Beat-Adresse vom Crossbar überhaupt nicht.** Es nimmt die
Start-Adresse einmal aus dem Burst-Header und zählt danach selbst hoch. Was auf den
Adressleitungen des Crossbars pro Beat steht, ist für die Funktion vollkommen egal —
solange die Dekodierung noch zum richtigen Endpoint zeigt.

Damit lässt sich derselbe Chip in zwei Betriebsarten fahren, die **funktional identisch**
sind und sich **nur** in der Schaltaktivität der Adressleitungen unterscheiden. Genau das
braucht man für eine saubere Isolierung.

---

## Der Aufbau

### Schritt 1 — Kompressor umschaltbar machen

In `rtl/croc_domain.sv:290-293` aus der festen Zuweisung eine Auswahl machen:

```systemverilog
always_comb begin
  xbar_mgr_obi_req[5] = idma_obi_read_req;
  xbar_mgr_obi_req[5].a.addr = addr_compress_en
      ? ReadEpAddr                                              // A: konstant
      : {ReadEpAddr[31:12], idma_obi_read_req.a.addr[11:0]};    // B: toggelnd
end
```

Analog für Port 4 mit `WriteEpAddr`.

**Warum die Maskierung auf `[11:0]` und nicht die volle Adresse?**
Die Endpoints liegen 0x1000 auseinander (`ReadEpAddr = 0x1100_0000`,
`WriteEpAddr = 0x1100_1000`). Die oberen 20 Bit konstant zu halten hält die
Crossbar-Dekodierung stabil beim richtigen Endpoint — Variante B bleibt garantiert im
4-KiB-Fenster des Read-Endpoints. Die unteren 12 Bit dürfen frei toggeln.

Das ist keine Verwässerung des Effekts: bei 256 B pro Kopie wandert die Adresse über
0x00–0xFF, es toggeln also Bits [7:2]. Die oberen Adressbits ändern sich innerhalb eines
Transfers ohnehin nicht — sie tragen im unkomprimierten Fall auch keine Aktivität bei.
Variante B reproduziert damit praktisch die **vollständige** reale Toggle-Aktivität des
unkomprimierten Designs.

Ohne die Maskierung würde Variante B den ersten Beat auf die echte iDMA-Quelladresse
legen, der Crossbar würde zum SRAM statt zum Endpoint routen, und der Test würde
schlicht fehlschlagen.

### Schritt 2 — das Steuerbit

Ein Bit, das die Software zur Laufzeit setzt. Sauberste Variante: ein Feld in `soc_ctrl`
(`rtl/soc_ctrl/`), per reggen erzeugt, z. B. `SOC_CTRL_ADDR_COMPRESS_OFFSET = 5'h18`.
Von dort als `addr_compress_en` nach `croc_domain` durchreichen.

Wichtig für die Messung: das Bit muss **vor** dem Trace-Fenster gesetzt werden, damit
das Schreiben selbst nicht mitgemessen wird. Also gleich am Anfang von `main()`, lange
vor dem ersten `idma_memcpy`.

### Schritt 3 — Backend genau einmal

```
yosys → openroad --all → spef.tcl
```

Ein Netlist. Ein SPEF. Beide Messungen benutzen **exakt dieselben Dateien**.

### Schritt 4 — zwei Software-Läufe

Zwei Binaries, die sich in genau einer Zeile unterscheiden:

```c
*(volatile uint32_t*)(SOC_CTRL_BASE + SOC_CTRL_ADDR_COMPRESS_OFFSET) = 1;  // bzw. 0
```

Beides mit `--build-postlayout` simulieren → `croc_compressed.vcd`, `croc_toggling.vcd`.

### Schritt 5 — PrimeTime zweimal

Im Skript wechselt **nur** `VCD` und `REPORT`. `NETLIST` und `SPEF` bleiben unverändert:

```tcl
set NETLIST .../croc.v      # identisch in beiden Läufen
set SPEF    .../croc.spef   # identisch in beiden Läufen
set VCD     .../croc_compressed.vcd    # bzw. croc_toggling.vcd
```

---

## Warum das methodisch stark ist

**Kein P&R-Rauschen.** Netlist und SPEF sind byte-identisch. Es gibt keine
Platzierungsunterschiede, keine anderen Leitungslängen, keine anderen Parasitics.

**Keine Zellzahl-Differenz.** Der Multiplexer ist in beiden Läufen dieselbe Hardware. Er
kürzt sich vollständig heraus — inklusive seiner eigenen Leakage.

**Gleiche Zyklenzahl.** Die Kompression ändert weder Handshakes noch Beat-Zahl. Beide
Läufe sollten exakt gleich lang sein. Das ist der eigentliche Gewinn: **wenn die
Zeitfenster identisch sind, ist die mittlere Leistung direkt vergleichbar.** Die ganze
Watt-versus-Joule-Diskussion aus dem Hauptreport entfällt.

**Deterministisch.** PrimeTime ist kein stochastisches Werkzeug. Bei identischem Netlist
und identischem SPEF ist jede Differenz im Ergebnis vollständig auf die unterschiedliche
Aktivität in der VCD zurückführbar. Es gibt keinen Rauschboden, gegen den man anmessen
müsste.

**Kontrollpunkt.** `rtl/burst/test/burst_addr_monitor.sv` ist schon instrumentiert und
zählt `real_toggles - xbar_toggles`. Der Monitor liefert die eingesparten Transitionen
als unabhängige Zahl — die muss zwischen den beiden Läufen genau um den erwarteten
Betrag differieren. Passt das nicht, stimmt am Aufbau etwas nicht.

---

## Ehrliche Erwartung zur Größenordnung

Die frühere Abschätzung (`power/addr_saving.py`, 16 Leitungen, mittlere Kapazität
23.98 fF, 13299 eingesparte Transitionen) ergab **0.230 nJ** über den ganzen Lauf.
Gegen 3991 nJ Gesamtenergie sind das **0.006 %**.

Das ist wenig. Es ist wahrscheinlich, dass am Ende eine Zahl in der vierten oder fünften
Nachkommastelle steht. Wer eine zweistellige Prozentersparnis erwartet, wird enttäuscht.

Der Punkt ist ein anderer: **weil kein Rauschen existiert, ist auch eine kleine Zahl
belastbar.** Statt „+9.4 %, aber wir wissen nicht wie viel davon P&R ist" bekommt man
„x nJ, und das ist exakt der Adresseffekt". Das ist wissenschaftlich der deutlich
stärkere Satz, auch wenn die Zahl kleiner ist.

---

## Billigere Alternative ohne neues Backend

Falls die Zeit für Synthese + P&R + zwei Post-Layout-Sims nicht reicht, gibt es einen
analytischen Weg mit den Daten, die schon vorliegen:

```
E_saved = ½ · C · V² · N_toggles
```

- **C** — die echte extrahierte Kapazität der Adressnetze, direkt aus
  `pt_package_20260720/burst/croc_burst.spef`. Keine Schätzung mehr wie in
  `addr_saving.py`, sondern die Werte aus der Extraktion.
- **N** — die eingesparten Transitionen aus `burst_addr_monitor.sv`, im
  RTL-Lauf gemessen.
- **V** — 1.2 V.

Das liefert eine rigorose **obere Schranke** für die Ersparnis, aufgeschlüsselt pro Netz,
und braucht weder ein neues Backend noch neue Simulationen. Schwächer als die
Zwei-VCD-Messung, weil es die Fanout-Buffer und die Interndissipation der getriebenen
Gatter nicht erfasst — aber es ist in Stunden statt Tagen zu haben und deutlich besser
begründet als der jetzige Netlist-gegen-Netlist-Vergleich.

Der Knackpunkt ist die Identifikation der Netze: nach der Synthese heißen die
Adressleitungen anonym `_NNNNN_`. Man muss sie über die Konnektivität finden
(iDMA-Read-Port → Crossbar-Manager 5), nicht über den Namen. `primetime/addr_wire_power.tcl`
hat das versucht und lieferte nur ein Netz — die Klassifikation dort ist zu eng gefasst
und müsste überarbeitet werden.

---

## Empfehlung

Wenn die Zeit reicht: **Schritt 1–5**. Es ist der einzige Aufbau, der die Frage
„Adresse konstant vs. Adresse toggelt" tatsächlich beantwortet, und der Aufwand liegt
bei einem Backend-Durchlauf plus zwei Simulationen.

Wenn nicht: **die analytische Schranke**, und im Bericht klar als solche kennzeichnen.

In beiden Fällen bleibt das Ergebnis des Hauptreports bestehen und unangetastet:
12.1 % weniger Zyklen, 3.8 % weniger Energie pro Transfer.
