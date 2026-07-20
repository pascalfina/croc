# Post-Layout Power Analysis — Burst vs. Baseline

**croc SoC, IHP SG13G2 · 20. Juli 2026 · PrimeTime PX Y-2026.03**

---

## Kurzfassung

Der Burst-Pfad bewegt dieselbe Datenmenge in **12.1 % weniger Zyklen** und braucht dafür
**3.8 % weniger Energie**. Die mittlere Leistungsaufnahme liegt dabei um 9.4 % höher —
der Gewinn kommt vollständig über die kürzere Laufzeit.

| Kennzahl | Baseline | Burst | Δ |
|---|---:|---:|---:|
| Laufzeit | 11014 Zyklen | 9682 Zyklen | **−12.1 %** |
| Energie pro Transfer | 4.1488 µJ | 3.9910 µJ | **−3.80 %** |
| Energie pro Byte | 317.67 pJ/B | 305.59 pJ/B | **−3.80 %** |
| Mittlere Leistung | 7.5334 mW | 8.2437 mW | +9.43 % |

---

## Messaufbau

Der Vergleich ist so aufgesetzt, dass beide Seiten bis auf die Hardware-Variante
identisch sind:

| | |
|---|---|
| Workload | `test_burst_huge.c`, NWORDS=64, REPS=50, OUTER=1 → 13060 B |
| Binary | **md5-identisch** in beiden Checkouts (`c1072767ef002ad9c537f897ed21c3e6`) |
| Testbench | byte-identisch, gleicher Trace-Start, gleiche JTAG-Sequenz |
| Netlist | Post-Layout aus OpenROAD, Top `croc_chip` (flach, mit Pad-Ring) |
| Parasitics | extrahiertes SPEF, keine Wire Load Models |
| Analyse | `time_based`, VCD aus Post-Layout-Gate-Level-Simulation |
| Takt | 20 MHz (`ClkPeriodSys = 50 ns`) |

**Trace-Fenster.** Der VCD-Dump startet erst nach dem JTAG-Laden des Binaries
(`$dumpvars` im Stimulus statt bei t=0). Ohne das wären ~86 % der Messung
JTAG-Shift-Rauschen gewesen. Beide Läufe starten bei exakt 1873850 ns.

**Annotationsgüte.** Vor der Messung geprüft:

| | Baseline | Burst |
|---|---:|---:|
| SPEF-Netze | 42627 | 46385 |
| davon mit VCD-Aktivität | 42627 (**100 %**) | 46385 (**100 %**) |

Kein einziges parasitäres Netz ohne Aktivitätsdaten. Ein früherer Versuch mit einer
Post-Synthesis-VCD gegen den Post-Layout-Netlist kam auf 14 % — OpenROAD benennt die
ABC-Zellen um (`$abc$…$245916` → `_08249_`). Die hier verwendeten VCDs stammen aus
echten Post-Layout-Läufen.

**Plausibilitätsprüfungen.** Switching Power liegt bei 1.6–1.9 mW. Mit Wire Load Models
statt SPEF wären es ~21 mW gewesen — die Parasitics sind also wirksam. Die Peak-Zeiten
(2011000 ns bzw. 2285800 ns) liegen in den jeweiligen Trace-Fenstern. Int + Switch + Leak
summiert sich in beiden Läufen exakt auf den Total-Wert.

---

## Ergebnisse

### Leistung

| Komponente | Baseline | Burst | Δ |
|---|---:|---:|---:|
| Internal | 5.8913 mW | 6.3732 mW | +8.18 % |
| Switching | 1.6333 mW | 1.8611 mW | +13.94 % |
| Leakage | 0.0087 mW | 0.0094 mW | +8.20 % |
| **Total** | **7.5334 mW** | **8.2437 mW** | **+9.43 %** |

### Energie

Beide Läufe bewegen exakt 13060 B. Über das jeweilige Zeitfenster integriert:

```
Baseline   7.5334 mW × 550.725 µs = 4.1488 µJ
Burst      8.2437 mW × 484.125 µs = 3.9910 µJ
                                    ────────
Ersparnis                          −0.1578 µJ   (−3.80 %)
```

---

## Interpretation

**Der Durchsatzgewinn ist real und sauber gemessen.** 1332 Zyklen weniger bei
identischem Binary und identischem Datenvolumen. Das ist der belastbarste Teil des
Ergebnisses und hängt an keiner Annahme über Parasitics oder Aktivitätsmodelle.

**Die Energieersparnis folgt daraus.** 3.8 % weniger Energie für dieselbe Arbeit.
Für ein energiebegrenztes System ist das die relevante Größe.

**Die höhere Leistungsaufnahme ist erwartbar und kein Widerspruch.** Dieselbe
Schaltarbeit auf einer um 12 % kürzeren Zeitachse ergibt mechanisch mehr Watt. Dazu
kommt die zusätzliche Burst-Hardware (Adresskompressor, `burst_endpoint_rw`,
lokale Beat-Adressgenerierung), die real schaltet. Ein vergleichbares Bild zeigen die
Messungen aus `note.md`: dort stieg der Total von 6.561 mW (`BurstMode = NONE`) auf
6.712 mW mit aktiviertem Burst.

---

## Einschränkungen

Zwei Punkte, die bei der Einordnung mitgelesen werden müssen:

**1. Der Versuch isoliert die Adresskompression nicht.**
Die beiden Netlists unterscheiden sich in der gesamten Burst-Hardware, nicht nur im
Adresspfad. Gemessen wird „Burst-Design vs. kein Burst-Design“, nicht
„Adresse konstant vs. Adresse toggelt“. Die Switching Power steigt um 13.9 % — also
genau in der Komponente, in der ein Adresseffekt sichtbar wäre, und in die
entgegengesetzte Richtung. Die Zusatzlogik schaltet mehr, als die konstant gehaltene
Crossbar-Adresse einspart.

**2. Getrennte Place-&-Route-Läufe.**
Baseline und Burst wurden unabhängig platziert und verdrahtet. Unterschiedliche
Platzierung erzeugt unterschiedliche Leitungslängen und damit unterschiedliche
Parasitics. Wie groß dieser Rauschanteil an den 9.4 % ist, wurde nicht quantifiziert.
`note.md` flaggt dasselbe Problem für die dortigen A/B/C/D-Läufe.

**Was belastbar behauptet werden kann:** 12.1 % weniger Zyklen und 3.8 % weniger
Energie pro Transfer bei nachweislich identischem Workload.

**Was nicht behauptet werden kann:** dass das Konstanthalten der Crossbar-Adresse für
sich genommen Leistung spart. Dieser Versuch stützt das nicht.

---

## Nächster Schritt: den Adresseffekt sauber isolieren

Siehe `power_report_next_experiment.md`.

---

## Rohdaten

```
Baseline  Int 5.891329e-03  Switch 1.633326e-03  Leak 8.717891e-06  Total 7.533373e-03
          Peak 3.141863e-01 @ 2011000-2011001 ns
          Fenster 1873850 .. 2424600 ns

Burst     Int 6.373228e-03  Switch 1.861064e-03  Leak 9.432464e-06  Total 8.243725e-03
          Peak 3.368638e-01 @ 2285800-2285801 ns
          Fenster 1873850 .. 2358000 ns
```

Artefakte: `pt_package_20260720/{burst,baseline}/` (Netlist, SPEF, VCD).
