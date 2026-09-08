# T09 — Mapa architektury vaulta

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `f3b624f`, branch `feature/agents-support`
- **Zależność:** T08 (`f3b624f`)

## Zakres wykonany

Dodano bieżącą mapę architektury `PlasmaVault`, która opisuje granice minimalnego proxy i
`delegatecall`, bezpośrednie punkty wejścia, routing fallbacku, storage clone'a, zewnętrzne
managery oraz reprezentatywne ścieżki deposit, execute i fallback. Dokument linkuje do
konkretnych plików źródłowych i katalogów testów zamiast powielać implementację.

| Plik                         | Opis                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------- |
| `docs/architecture.md`       | Nowa kanoniczna mapa bieżącej architektury vaulta i przepływów wywołań.         |
| `docs/README.md`             | Link do mapy i rozróżnienie dokumentu bieżącego od starszego opisu komponentów. |
| `contracts/vaults/README.md` | Ostrzeżenie, że opis osobnego komponentu ERC-4626 jest historyczny.             |
| `AGENTS.md`                  | Mapa repo kieruje najpierw do bieżącego dokumentu architektury.                 |
| `.gitignore`                 | Wąski wyjątek pozwalający śledzić wyłącznie `docs/architecture.md`.             |
| `agent-readiness/PLAN.md`    | Checkbox T09 zmieniony na `[x]`.                                                |
| `agent-readiness/STATUS.md`  | T08 uzgodnione z historią Git; T09 ustawione na `ready-for-commit`.             |

## Zweryfikowane ścieżki

1. **Deposit** — `deposit` przechodzi przez `nonReentrant` i `restricted`, `_checkCanCall`
   sprawdza callera i receivera oraz uruchamia pre-hook, a `_deposit` realizuje management
   fee, wywołuje ERC-4626 deposit i w razie opłaty mintuje różnicę udziałów do
   `WithdrawManager`. Aktualizacja udziałów przechodzi przez delegowany
   `PlasmaVaultBase.updateInternal`.
2. **Execute** — `execute` zapisuje NAV przed operacją, ustawia flagę wykonania, sprawdza
   obsługiwane fuse'y, zbiera market IDs, deleguje akcje, czyści flagę, aktualizuje zależne
   salda i limity oraz realizuje performance fee.
3. **Fallback** — aktywne wykonanie ma pierwszeństwo i trafia do `CallbackHandlerLib`;
   jawne selektory głosowania trafiają do opcjonalnego pluginu; wszystkie pozostałe
   selektory są delegowane do `PlasmaVaultBase`.

## Kroki i weryfikacja

1. Odczytano `PlasmaVault`, `PlasmaVaultBase`, governance, router pre-hooków, context client,
   biblioteki storage i marketów, factory oraz kontrakty managerów.
2. Potwierdzono, że `PlasmaVaultFactory.clone` używa `Clones.clone`, a storage i aktywa
   należą do adresu clone'a mimo zagnieżdżonych delegatecalli.
3. Potwierdzono symbole: `fallback`, `proxyInitialize`, `execute`, `deposit`, `_deposit`,
   `_updateMarketsBalances`, `_checkCanCall`, `_msgSender`, `_update` i
   `PlasmaVaultBase.updateInternal`.
4. Wyszukiwanie w `contracts/**/*.sol` potwierdziło brak bieżących symboli
   `PlasmaVaultErc4626` oraz `_isERC4626ViewFunction`; starszy README otrzymał ostrzeżenie.
5. Lokalny checker przeszedł po linkach w `AGENTS.md`, `docs/README.md`,
   `docs/architecture.md` i `contracts/vaults/README.md`: zero brakujących celów.
6. `git check-ignore --no-index docs/architecture.md` potwierdził, że nowy dokument nie jest
   ignorowany.
7. Prettier zaakceptował `AGENTS.md`, indeks, nową mapę i artefakty T09. Starszy vault
   README ma zastane odchylenia i nie został przeformatowany, aby uniknąć ubocznego churnu.
   Testów kontraktów nie uruchamiano, ponieważ zakres jest dokumentacyjny; kryterium
   ścieżek zweryfikowano bezpośrednio względem kodu.

## Odstępstwa od planu

Brak. Ostrzeżenie w starszym `contracts/vaults/README.md` jest konieczną korektą
odkrywalności: plik nadal zawiera wartościowe szczegóły, ale jego opis osobnego komponentu
ERC-4626 nie odpowiada bieżącemu checkoutowi.

## Follow-upy (poza zakresem, NIE zrobione)

- T10 opisze role fabryki i vaulta, administratorów, opóźnienia oraz caller kontra owner.
- T11–T12 dodadzą instrukcje katalogowe dla fabryk i fuse'ów.
- Aktualni posiadacze ról na wdrożeniach nie są deklarowani bez dowodów on-chain.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.
