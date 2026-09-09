# T37 — Mapa niezmienników i ich testów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T09 (`1ea8233`), T30 (ready-for-commit), T36 (ready-for-commit)

## Zakres wykonany

- `docs/invariants.md` — 23 własności pilotażu w czterech grupach (księgowanie i
  wycena, opłaty, wypłaty, uprawnienia i limity), każda oznaczona jako
  **tested** albo **postulated**, z odnośnikiem do dowodu i podaną tolerancją.
  Osobna sekcja o zaokrągleniach i tolerancjach oraz lista czterech luk do
  zamknięcia.
- `.gitignore` i `docs/README.md` — wyjątek i wpis w indeksie.

## Kroki

1. **Źródła oznaczeń** — wyłącznie przebiegi z T25–T36 oraz istniejące testy w repo; nic nie zostało oznaczone „tested" na podstawie samego kodu.
2. **Kontrola odnośników** — wszystkie ścieżki istnieją, cytowane nazwy testów znalezione w plikach (`runs.txt`).
3. **Luki** — cztery najważniejsze (W1, P4, P5, A6) wypisane wprost jako osobne zadania.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| `docs/invariants.md` dla księgowania, opłat, wypłat i uprawnień pilotażu | cztery tabele: A1–A7, F1–F5, W1–W5, P1–P7 | ✅ |
| Odnośniki do testów, rounding i tolerancji | każda pozycja `tested` wskazuje plik i asercję; osobna sekcja „Rounding and tolerances" | ✅ |
| Każda własność ma „testowana" albo „postulowana" | 12 tested, 11 postulated, brak stanu pośredniego | ✅ |
| Luki w testach są jawne | sekcja „Gaps worth closing" z czterema pozycjami | ✅ |
| Nowe testy większych braków to osobne zadania | zapisane jako follow-upy, nie dopisywane do tego zadania | ✅ |

## Odstępstwa od planu

- Brak. Dokument celowo nie uruchamia testów kontraktowych — opisuje dowody,
  które już powstały w T25–T36.

## Follow-upy (poza zakresem, NIE zrobione)

- W1: test, że redeem przed upływem redemption delay się nie udaje.
- P4: test, że wdrożony fuse odrzuca substrate spoza listy.
- P5: przeniesienie zaobserwowanego `MarketLimitExceeded` do commitowanego testu.
- A6: scenariusz z narastaniem wartości (fork z dwoma blokami albo przewijanie
  czasu na rynku, który nalicza odsetki).
