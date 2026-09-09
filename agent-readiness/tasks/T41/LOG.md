# T41 — Jeden adapter podpisywania i wykonania EOA

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T39 (ready-for-commit), T40 (ready-for-commit)

## Zakres wykonany

- `tools/execute-plan.mjs` (`vault:execute`) — jedyna ścieżka wysyłająca
  transakcję: kontrola zakresu → preflight → wpis do dziennika → `cast send` z
  calldata planu bez zmian → rozstrzygnięcie wpisu z łańcucha.
- `config/execution/scope.example.json` — zakres jako plik: sieć, dozwolone
  adresy docelowe, selektory, nadawcy, maksymalna wartość i limit gazu.
- `tools/test-execute-plan.mjs` — 4 testy.
- `docs/vaults.md` — sekcja „Executing an approved plan (EOA)" z opisem, gdzie
  jest klucz i gdzie go nigdy nie ma.
- `package.json` — `vault:execute`, `vault:execute:test`.

## Kroki

1. **Uzgodniony sposób podpisywania** — konto keystore Foundry (`cast wallet import`), przekazywane po nazwie (`--account`); klucz nigdy nie jest argumentem procesu. `--private-key`, `--mnemonic` i `--interactive` są odrzucane kodem `KEY_IN_ARGUMENT`.
2. **Zakres jako autoryzacja** — cztery kontrole (sieć, cel, selektor, nadawca) plus limit wartości; odmowa **przed** dostępem do sieci i bez wpisu w dzienniku.
3. **Preflight i dziennik** — wykorzystane bezpośrednio: „stop" nie wysyła i nie zapisuje; nieudana wysyłka ustawia wpis na `unknown` i odsyła do `sync`.
4. **Testy na forku** — `npm run vault:execute:test` → 4/4; przebieg w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Jeden uzgodniony sposób podpisywania, zewnętrzny względem promptu | konto keystore Foundry; repo zna tylko jego nazwę | ✅ |
| Wykorzystuje preflight i dziennik | kroki 2–5 narzędzia; testy „preflight stop" i „journal confirmed" | ✅ |
| Testy na Anvil/forku, bez operacji na mainnecie | wszystkie testy na lokalnym anvilu; brak jakiejkolwiek wysyłki do sieci publicznej | ✅ |
| Wykonywane wyłącznie dane zatwierdzonego planu w zadanym zakresie | calldata brana dosłownie z pliku planu; cztery testy odmowy poza zakresem | ✅ |
| Klucz nie trafia do raportu, promptu ani argumentów widocznych w logach | `KEY_IN_ARGUMENT` dla argumentów z kluczem; asercja, że wyjście nie zawiera „private key"/„mnemonic"/„password"; wpis dziennika trzyma hash calldata, nie klucz | ✅ |

## Odstępstwa od planu

- Ścieżka z realnym kluczem (`--account`) nie jest testowana automatycznie —
  wymagałaby klucza na tej maszynie. Testy pokrywają identyczną logikę na forku
  (`--fork-unlocked`), różnicą są tylko dwa argumenty przekazywane do `cast send`.

## Follow-upy (poza zakresem, NIE zrobione)

- Zakres nie ogranicza czasu ani liczby wykonań; polityka „ile razy w oknie
  czasowym" to osobna decyzja.
- Ścieżka Safe (T42) potrzebuje własnego eksportu i własnej symulacji, bo zmienia
  `msg.sender` widziany przez fabrykę.
