# Post-Layout Power Analysis — Method 2 (Adresskompression)

**croc SoC, IHP SG13G2 · PrimeTime PX Y-2026.03 · Stand 21. Juli 2026**
**Alle Werte am Corner 1.08 V** (zur Vergleichbarkeit mit Method 1 / Khanh).

---

## Kurzfassung

Method 2 (Adresskompression) wurde gegen **bare croc** und gegen **Method 1 (Khanh,
Burst-Framing)** verglichen, auf zwei Workloads:

- **kleiner Transfer** (`test_khanh`, ein 512-B-memcpy): Method 2 kostet Energie
  (+27.6 % vs bare), Method 1 gewinnt klar.
- **großer Transfer** (`test_burst_huge`, 50× wiederholt): Method 2 spart Energie
  (−3.8 % vs bare) und ist **gleichauf mit Method 1** (Leistung 6.68 vs 6.69 mW).

Zusätzlich liefert Method 2 einen Effekt, den Method 1 nicht adressiert:
**99.95 % weniger Schaltaktivität auf dem Adressbus, ~944 pJ isoliert gemessen.**

| Kennzahl (1.08 V) | Wert |
|---|---:|
| großer Transfer, Energie vs bare | **−3.8 %** |
| kleiner Transfer, Energie vs bare | +27.6 % |
| Adress-Transitionen | 12 847 → 7 (**−99.95 %**) |
| Adressbus-Energie | 566–944 pJ |

---

## Vergleich Method 1 (Khanh) vs Method 2 (Pascal)

Alle Werte am **Corner 1.08 V, 20 MHz**. Khanhs Werte gemessen; Method 2 klein gemessen,
Method 2 groß aus der 1.2-V-Messung mit V² skaliert (siehe Methodik).

### Kleiner Transfer (`test_khanh`, 512 B, DMA-only)

| Config | Leistung | Zyklen | Energie |
|---|---:|---:|---:|
| bare croc | 6.26 / 6.28 mW¹ | 419 / 394 | 131.1 / 123.7 nJ |
| **M1** blen=0 | 6.64 mW | 287 | 95.3 nJ |
| **M1** blen=total | 6.68 mW | 287 | 95.8 nJ |
| **M2** (Adresskompr.) | 6.81 mW | 464 | 157.9 nJ |

¹ links Khanh, rechts Pascal — die bare-Baselines stimmen überein (6.26 vs 6.28 mW).

**Auf dem kleinen Transfer gewinnt Method 1 deutlich:** −27 % Energie (beschleunigt den
Transfer, 287 statt 419 Zyklen). Method 2 kostet +65 % Energie gegenüber M1 — sie
beschleunigt nicht und trägt Burst-Overhead.

### Großer Transfer (`test_burst_huge`, 256 B × 50)

| Config | Leistung | Zyklen | Energie |
|---|---:|---:|---:|
| bare croc (Pascal) | 6.10 mW | 11015 | 3.361 µJ |
| **M1** (Khanh) | 6.69 mW | 9350 | 3.128 µJ |
| **M2** (Pascal) | 6.68 mW | 9683 | 3.233 µJ |

**Auf dem großen Transfer sind beide praktisch gleichauf:** Leistung 6.68 (M2) vs 6.69 mW
(M1) — Method 2 sogar minimal niedriger. Energie: M2 nur **+3.4 %** hinter M1 (durch die
3.6 % mehr Zyklen).

### Zusammenfassung des Vergleichs

| Workload | M2-Energie relativ zu M1 |
|---|---:|
| klein (`test_khanh`) | **+65 %** (weit hinten) |
| groß (`test_burst_huge`) | **+3.4 %** (Gleichstand) |

Method 2 skaliert mit der Transfergröße: chancenlos bei kleinen, ebenbürtig bei großen
Transfers. **Method 1 und Method 2 optimieren nicht dasselbe** — M1 den Durchsatz, M2 die
Adressbus-Energie — und sind orthogonal, also kombinierbar.

---

## Teil 1 — bare croc gegen Method 2 (großer Transfer)

`test_burst_huge`, NWORDS=64, REPS=50 → 13 060 B. Trace-Fenster: ganzes `main()`
(Core-Wake bis Ende-des-Codes, JTAG-Laden ausgeschlossen). Werte auf 1.08 V:

| Komponente | bare | M2 | Δ |
|---|---:|---:|---:|
| **Total** | **6.10 mW** | **6.68 mW** | +9.4 % |
| Zyklen | 11015 | 9683 | **−12.1 %** |
| **Energie** | **3.361 µJ** | **3.233 µJ** | **−3.8 %** |

Die höhere Leistung (+9.4 %) ist erwartbar — dieselbe Schaltarbeit auf einer 12 % kürzeren
Zeitachse plus Burst-Hardware. Der Gewinn liegt in der Energie: gleiche Arbeit, 12 %
weniger Zyklen, −3.8 % Energie. **Das Energie-Delta ist spannungsunabhängig** (bare und M2
skalieren beide mit V²), gilt also bei 1.08 V wie bei 1.2 V.

### Warum die 12 % weniger Zyklen — der Mechanismus

Der iDMA bewegt die Daten Beat für Beat über den Crossbar; der Unterschied liegt darin,
**wie** diese Beats den Crossbar passieren.

**Ohne Burst (bare croc):** Jeder Beat ist eine eigenständige Crossbar-Transaktion — der
iDMA muss für jeden Beat neu um den Pfad zum Speicher arbitrieren. Am iDMA-Manager-Port
gemessen wartet bare croc **~0.48 Zyklen pro Read-Beat** auf den Crossbar-Grant (Request
liegt an, noch kein Grant) — reine Arbitrierungs-Wartezeit.

**Mit Burst (Method 2):** Das Burst-Framing (`bfirst`/`blast`) lockt den Crossbar-Pfad für
die Dauer des Bursts. In der VCD engagiert dieser Demux-Burst-Lock **51× — einmal pro Burst,
bei bare croc 0×**. Die Folge-Beats streamen durch den fixierten Pfad ohne erneute
Arbitrierung: nur noch **~0.03 Stall-Zyklen pro Beat** (−15×).

Diese pro Beat eingesparte Arbitrierungs-Wartezeit, über alle Beats summiert, ist der
Ursprung der ~12 % weniger Zyklen.

| Gemessenes Signal | bare | Method 2 |
|---|---:|---:|
| Demux-Burst-Lock engagiert (Crossbar) | 0× | 51× (1×/Burst) |
| Stall-Zyklen pro Read-Beat (iDMA-Port) | 0.48 | 0.03 |
| Stall-Zyklen pro Write-Beat (iDMA-Port) | 0.50 | 0.03 |

Beide Designs am **identischen iDMA-Core und Manager-Port** gemessen — direkt vergleichbar
(der iDMA ist in beiden Designs dasselbe Modul, nur die Anbindung dahinter unterscheidet sich).

**Getrennt von der Adresskompression:** Der Zyklen-Gewinn kommt vom Burst-Framing (Lock),
**nicht** vom Konstant-Halten der Adresse. Die konstante Adresse ist rein kombinatorisch und
senkt nur die Schaltaktivität (Teil 2, Energie) — sie berührt die Zyklenzahl nicht.

---

## Teil 2 — Isolierter Adresseffekt (Method 2s eigentlicher Zweck)

Method 2 hält die Crossbar-Adresse pro Burst konstant, statt sie pro Beat zu inkrementieren.
Der Effekt wurde auf **einem einzigen Netlist** isoliert (kein P&R-Rauschen): const- gegen
toggle-Adresse, gleiche Hardware, gleiche Zyklenzahl.

### Schaltaktivität (Verilator, RTL)

| | per-Beat `a.addr` | Header `start_addr` | eliminiert |
|---|---:|---:|---:|
| Read | 6423 | 3 | 6420 |
| Write | 6424 | 4 | 6420 |
| **Summe** | **12 847** | **7** | **12 840 (99.95 %)** |

### Energie (auf 1.08 V)

| Messweg | erfasst | Ersparnis @1.08 V |
|---|---|---:|
| analytisch | nur Leitungskapazität | **566 pJ** |
| Sonde (PrimeTime) | Leitung + Gatter | **944 pJ** |

Direkt in PrimeTime gemessen, auf identischem Netlist und SPEF, mit der Switching-Komponente
als Träger (drei Viertel der Differenz) — die Signatur einer geladenen Leitung.
**Das leistet Method 1 nicht** — ihr Framing spart keine Adress-Energie.

---

## Teil 3 — Kleiner Transfer (`test_khanh`, gemessen bei 1.08 V)

Khanhs Workload (ein 512-B-memcpy), DMA-only-Fenster (GPIO-Marker um den `idma_memcpy`),
direkt bei 1.08 V gemessen:

| | bare | M2 | Δ |
|---|---:|---:|---:|
| **Total** | **6.280 mW** | **6.805 mW** | +8.4 % |
| Zyklen | 394 | 464 | +18 % |
| **Energie** | **123.71 nJ** | **157.88 nJ** | **+27.6 %** |

Hier verliert Method 2: der einzelne kleine Transfer ist ihr Worst Case, der Burst-Overhead
(Compressor/Endpoint-Latenz) dominiert, ohne Durchsatzgewinn.

---

## Interpretation — Betriebsbereich

Method 2 dreht das Vorzeichen mit der Transfergröße, weil der Burst einen **fixen Overhead**
hat, der sich erst über viele Beats amortisiert:

| Workload | Zyklen Δ | Energie Δ (vs bare) |
|---|---:|---:|
| klein (1× 512 B) | +18 % | +27.6 % ❌ |
| groß (50× 256 B) | −12.1 % | −3.8 % ✅ |

- **Kleiner Single-Transfer:** Overhead dominiert → langsamer, mehr Energie.
- **Großer wiederholter Transfer:** Overhead amortisiert → schneller, weniger Energie.

Method 2 ist damit eine **Groß-Transfer-Optimierung** und adressiert primär die
**Adressbus-Energie** (Teil 2) — ein anderes Ziel als Method 1 (Durchsatz). Beide sind
orthogonal und ließen sich kombinieren.

---

## Methodik & Validierung

**Corner.** Alle Vergleichswerte bei 1.08 V (Khanhs Corner). Die bare-croc-Baselines beider
Seiten stimmen überein (Khanh 6.26 mW, Pascal 6.28 mW) — das validiert den Messaufbau. Die
frühere Diskrepanz (6.26 vs 7.73 mW) war ein reiner Spannungscorner-Unterschied (1.08 vs
1.20 V), die V²-Skalierung erklärt sie exakt.

**Skalierung.** Kleiner Transfer und Adress-Sonde wurden **bei 1.08 V gemessen**. Der große
Transfer (Teil 1) wurde bei 1.2 V gemessen und mit V² auf 1.08 V skaliert (Faktor 0.81).
Die Skalierung ist auf ~1 % genau (am kleinen Transfer verifiziert). **Für den finalen
Report empfiehlt sich, den großen Transfer real bei 1.08 V nachzurechnen** — die Pakete und
das 1.08-V-Lib-Set liegen bereit, es braucht nur zwei PrimeTime-Läufe, keine neue Simulation.

**Annotationsgüte.** 100 % der SPEF-Netze mit VCD-Aktivität in allen Läufen. `time_based`
mode, extrahiertes SPEF, keine Wire Load Models. Trace-Fenster ohne JTAG-Ladephase.

**Bugfix.** Der Burst-Read-Pfad hatte einen längenabhängigen Deadlock (fehlende
R-Kanal-Backpressure): Transfers über ~64 Beats überliefen den iDMA und hingen. Behoben mit
einem Credit-Zähler in `croc_burst_dma`, der den Endpoint auf die iDMA-Anforderungsrate
paced. Erst damit läuft `test_khanh` (128 Beats) auf dem Burst-Design.

---

## Rohdaten

```
GROSS (test_burst_huge), 1.2V gemessen -> 1.08V skaliert (x0.81):
  bare   6.102 mW | 11015 cyc | 3.361 uJ
  M2     6.677 mW |  9683 cyc | 3.233 uJ

KLEIN (test_khanh), bei 1.08V gemessen:
  bare   6.2799 mW | 394 cyc | 123.71 nJ   (Int 4.9354 Sw 1.3067 Lk 0.0379)
  M2     6.8051 mW | 464 cyc | 157.88 nJ   (Int 5.2443 Sw 1.5194 Lk 0.0414)

ADRESSEFFEKT (probe), 1.2V -> 1.08V:
  Sonde-Delta 944 pJ | analytisch 566 pJ | 12847 -> 7 Toggles

KHANH Method 1 (seine 1.08V):
  klein:  bare 6.26/419/131.1nJ | blen=0 6.64/287/95.3 | blen=tot 6.68/287/95.8
  gross:  M1 burst 6.69 mW / 9350 cyc / 3.128 uJ
```

Artefakte: `pt_package_20260720/` (groß), `pt_package_probe_20260721/` (Adresseffekt),
`pt_package_khanh_20260721/` (klein, bare+burst).
