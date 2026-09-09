# T52 — Opcjonalny odczyt manifestów i inspekcja przez MCP

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T24 (`562fea3`), T26, T46 (ready-for-commit)

## Zakres wykonany

- `tools/mcp-server.mjs` (`mcp:deployments`) — serwer MCP po stdio z dwoma
  narzędziami tylko do odczytu: `list_deployments` (manifesty repo wraz z
  dowodami weryfikacji) i `inspect_factory` (uruchamia ten sam inspektor co CLI).
- `tools/test-mcp-server.mjs` — 4 testy, w tym porównanie MCP z CLI.
- `docs/mcp.md` (+ `.gitignore`, indeks) — co potrafi istniejący serwer, czego
  nie, jak skonfigurować klienta i czego te narzędzia nie robią.
- `.github/workflows/pr-checks.yml` — `mcp:deployments:test` w jobie bez sekretów.
- `package.json` — `mcp:deployments`, `mcp:deployments:test`.
- Ośmiu testom narzędzi ujednolicono wykrywanie providera (`FUSION_ENV_FILE`),
  żeby przebieg bez providera pomijał testy zamiast je oblewać.

## Kroki

1. **Najpierw możliwości istniejącego MCP** — `server_info` (SDK 3.6.7) i lista narzędzi: dyskoveria adresów, ABI/źródła z explorera, dane vaultów i keepera. Brak dostępu do manifestów, raportów weryfikacji i testów zgodności z tego repo — czyli do nowych dowodów zgodności.
2. **Minimalny zakres** — dokładnie dwa narzędzia z planu, bez własnego rejestru: `list_deployments` czyta `deployments/**/factories.json`, `inspect_factory` woła `tools/inspect-factory.mjs`.
3. **Zgodność CLI/MCP** — test porównuje sparsowany JSON obu ścieżek dla tego samego wejścia (`deepEqual`, nie snapshot).
4. **Brak wysyłania transakcji** — test asertuje listę narzędzi i wzorzec nazw; poza tym serwer nie ma żadnej ścieżki zapisu.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Najpierw sprawdzić możliwości istniejącego MCP | `server_info` + lista narzędzi; wnioski w `docs/mcp.md` i [`runs.txt`](runs.txt) | ✅ |
| Dodać tylko `list_deployments` i `inspect_factory` | `tools/list` zwraca dokładnie te dwa | ✅ |
| Współdzielenie implementacji z CLI | `inspect_factory` uruchamia `tools/inspect-factory.mjs`; `list_deployments` czyta te same manifesty | ✅ |
| Bez tworzenia drugiego rejestru | brak własnych danych; wszystko z `deployments/` | ✅ |
| Te same dane wejściowe dają ten sam wynik CLI/MCP | test `deepEqual` dla bloku 25937526 i tego samego callera | ✅ |
| Brak możliwości wysyłania transakcji | dwa narzędzia odczytu; test na nazwy; brak signera i brak zapisu | ✅ |

## Odstępstwa od planu

- Istniejący serwer **nie** wystarczał (nie zna manifestów ani dowodów), więc
  zamiast samej recepty powstały dwa narzędzia — dokładnie te, które plan
  dopuszcza w tym przypadku. `docs/mcp.md` opisuje też, kiedy używać którego
  serwera.
- Protokół MCP zaimplementowano ręcznie (stdio JSON-RPC), żeby nie dodawać
  zależności i nie ruszać `package-lock.json`.

## Follow-upy (poza zakresem, NIE zrobione)

- Ewentualne `explain_revert`, `plan_vault`, `simulate_vault` — plan wymienia je
  jako możliwe, ale wymagają decyzji, czy operacje mają być dostępne przez MCP.
- Publikacja konfiguracji klienta w repozytorium (dziś to przykład w dokumencie).
