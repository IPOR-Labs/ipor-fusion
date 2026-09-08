# Status zadań planu agent-readiness

Statusy: `todo` · `in-progress` · `ready-for-commit` (zaimplementowane, czeka na ręczny commit
Pete'a) · `committed <hash>` · `partial` · `blocked`. Aktualizuje agent (skill `readiness-task`,
krok 0 i 5) oraz Pete po commicie.

| ID | Zadanie | Prio | Zależności | Status | Data | Uwagi |
| --- | --- | --- | --- | --- | --- | --- |
| T00 | Pomiar bazowy | P0 | — | partial `7d64650` | 2026-09-07 | `evals/agent-readiness/` gotowe (tasks.json + baseline.md); brak przebiegu 1 — decyzją Pete'a (2026-09-07) odłożony na koniec i na osobny branch; przepis na przebieg w `tasks/T01/LOG.md` (Follow-upy) |
| T01 | Selektywne wersjonowanie dokumentacji | P0 | T00 | ready-for-commit | 2026-09-07 | `.gitignore`: `docs/*` + `!docs/README.md`; nowy indeks `docs/README.md`; zależność od T00 pominięta za zgodą Pete'a |
| T02 | Przykład konfiguracji RPC | P0 | T01 | todo | | |
| T03 | Instalacja zgodna z lockfile | P0 | T02 | todo | | |
| T04 | Przypięcie wersji Foundry | P0 | T03 | todo | | lokalnie 1.7.1, CI `stable` — wybrać wersję |
| T05 | Kontrola formatowania bez zapisu | P0 | T03 | todo | | |
| T06 | Spójne formatowanie w pre-commit | P1 | T05 | todo | | |
| T07 | Usunięcie martwej komendy coverage | P1 | T03 | todo | | |
| T08 | Wspólny punkt wejścia (AGENTS.md) | P0 | T01, T04, T05 | todo | | |
| T09 | Mapa architektury | P1 | T08 | todo | | |
| T10 | Mapa ról i wywołujących | P0 | T09 | todo | | |
| T11 | Instrukcje pracy nad fabrykami | P0 | T08, T10 | todo | | |
| T12 | Instrukcje pracy nad fuse'ami | P1 | T08, T09 | todo | | |
| T13 | Katalog testów dla pilotażu | P0 | T04, T11 | todo | | |
| T14 | Jawne profile testów | P0 | T13 | todo | | |
| T15 | Lokalny zestaw bez RPC | P0 | T13, T14 | todo | | |
| T16 | Runner jednego zestawu na forku | P0 | T13, T14 | todo | | |
| T17 | agent:doctor lokalny | P0 | T03, T04, T13 | todo | | |
| T18 | agent:doctor RPC | P0 | T16, T17 | todo | | |
| T19 | test:affected | P1 | T13, T15, T16 | todo | | |
| T20 | Źródło adresów i wybór pilotażu | P0 | T11 | todo | | wymaga MCP `fusion_address_lookup` / ipor-abi |
| T21 | Schemat i walidator manifestów | P0 | T20 | todo | | |
| T22 | ABI jednej wdrożonej wersji | P0 | T20, T21 | todo | | |
| T23 | Manifest pierwszego kandydata | P0 | T21, T22 | todo | | |
| T24 | factory:inspect | P0 | T18, T23 | todo | | |
| T25 | Test tworzenia przez niezmienioną fabrykę | P0 | T16, T24 | todo | | |
| T26 | Promocja pilotażu do verified | P0 | T24, T25 | todo | | |
| T27 | Walidowana konfiguracja vaulta | P0 | T10, T26 | todo | | |
| T28 | vault:plan | P0 | T24, T27 | todo | | |
| T29 | vault:simulate | P0 | T25, T28 | todo | | |
| T30 | Verifier stanu vaulta | P0 | T29 | todo | | |
| T31 | vault:verify z receipt | P0 | T30 | todo | | |
| T32 | Recepta create-vault | P0 | T26, T28–T31 | todo | | |
| T33 | Katalog jednej integracji ERC4626 | P1 | T12, T20 | todo | | |
| T34 | Generator katalogu | P1 | T33 | todo | | |
| T35 | Plan konfiguracji strategii ERC4626 | P1 | T10, T30, T33 | todo | | |
| T36 | Test pełnego cyklu środków | P1 | T32, T35 | todo | | |
| T37 | Mapa niezmienników | P1 | T09, T30, T36 | todo | | |
| T38 | Troubleshooting | P1 | T18, T24, T31, T36 | todo | | |
| T39 | Preflight przed wykonaniem | P1 | T28–T30 | todo | | |
| T40 | Dziennik transakcji | P1 | T31, T39 | todo | | |
| T41 | Adapter EOA | P1 | T39, T40 | todo | | |
| T42 | Eksport Safe | P1 | T10, T28, T29, T39 | todo | | |
| T43 | CI bez sekretów | P0 | T04, T05, T15 | todo | | ustawień GitHub environments nie sprawdzimy z VM |
| T44 | Zaufany job forkowy | P1 | T16, T18, T25, T43 | todo | | |
| T45 | Kontrola aktualności docs/artefaktów | P1 | T21, T26, T34, T43 | todo | | |
| T46 | Drift pilotażowej fabryki | P1 | T24, T26, T44 | todo | | |
| T47 | CODEOWNERS i proces wydania | P1 | T26, T45 | todo | | |
| T48 | Benchmark vs baseline | P1 | T00, T19, T32, T36, T38 | todo | | |
| T49 | Fabryka price feedu | P2 | T21, T24, T32, T33 | todo | | |
| T50 | Wariant wrappera | P2 | T21, T24, T32 | todo | | |
| T51 | Dodatkowa sieć | P2 | T16, T24, T32, T44 | todo | | |
| T52 | MCP inspect | P2 | T24, T26, T46 | todo | | |
