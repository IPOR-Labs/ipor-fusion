# T38 — Procedura diagnozowania najczęstszych błędów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T18 (`5f70266`), T24 (`562fea3`), T31 (ready-for-commit), T36 (ready-for-commit)

## Zakres wykonany

- `docs/troubleshooting.md` — objawy w sześciu grupach: środowisko i RPC,
  tożsamość wdrożenia i ABI, role, opłaty, substrates/rynki/oracle oraz wynik
  transakcji. Każdy wpis podaje dokładny komunikat, co znaczy i komendę
  potwierdzającą przyczynę.
- `.gitignore` i `docs/README.md` — wyjątek i wpis w indeksie.

## Kroki

1. **Objawy z realnych przebiegów** — wszystkie komunikaty pochodzą z zadań T18, T24, T28–T31, T35 i T36; mapowanie w [`runs.txt`](runs.txt).
2. **Wykonanie każdej komendy diagnostycznej** — na przypiętym bloku Ethereum oraz na lokalnym forku z vaultem utworzonym i skonfigurowanym narzędziami z repo.
3. **Nieoczywisty wynik z praktyki** — `getSourceOfAssetPrice(USDC)` zwraca adres zerowy, mimo że `getAssetPrice` odpowiada (fallback na globalny middleware); dokument ostrzega, żeby nie czytać tego jako braku źródła ceny.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Konkretne błędy RPC, ABI, ról, opłat, substrates i oracle | sześć sekcji, 20 wpisów z dosłownymi komunikatami | ✅ |
| Komendy prowadzące do rozpoznania | każda komenda uruchomiona; wyniki w `runs.txt` | ✅ |
| Przykłady pochodzą z istniejących testów/raportów | tabela mapująca objaw → zadanie, w którym wystąpił | ✅ |
| Od objawu do sprawdzenia przyczyny, bez zgadywania naprawy | wpisy kończą się na sprawdzeniu; jedyne zdania nakazowe to ostrzeżenia bezpieczeństwa (nie wysyłać ponownie transakcji przy `pending`) | ✅ |

## Odstępstwa od planu

- Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- `vault:simulate` nie dekoduje powodu rewertu; gdy powstanie dekoder błędów
  fabryki i fuse'ów, sekcja „Transactions and results" powinna go wskazywać.
- Warto dodać wpis o błędach specyficznych dla Safe/kontraktowego callera, gdy
  ścieżka z T42 będzie istnieć.
