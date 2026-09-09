# T43 — Podstawowe CI bez sekretów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T04 (`7364631`), T05 (`024509c`), T15 (`b0bbd2a`)

## Zakres wykonany

- `.github/workflows/pr-checks.yml` — job dla `pull_request`, `permissions:
  contents: read`, **bez sekretów**: build, solhint, `format:check` (raportujący),
  `test:unit`, komplet walidatorów i testy narzędzi niewymagające providera
  (uruchamiane z `FUSION_ENV_FILE=/dev/null`).
- `docs/ci.md` — podział na job bez sekretów i workflow uprzywilejowany, opis
  baseline'u formatowania oraz jawne stwierdzenie, czego (ustawień environments)
  nie da się sprawdzić z repozytorium.
- `.gitignore`, `docs/README.md` — wyjątek i wpis w indeksie.

## Kroki

1. **Wybór kontroli offline** — każdy skrypt uruchomiony bez zmiennych providera; lista w [`runs.txt`](runs.txt). `agent:doctor:test` odpada (wymaga RPC) i jest to zapisane.
2. **Pomiar baseline'ów** — `solhint:all` przechodzi (same warningi), `format:check` zgłasza 301 plików sprzed tego zadania.
3. **Kształt workflow** — sparsowany YAML: wyzwalacz `pull_request`, uprawnienia `contents: read`, brak odwołań do `secrets.`.
4. **Przegląd ścieżki PR z forka** — `ci.yml` (`pull_request_target`) checkoutuje merge PR-a z sekretami; jedyną barierą jest job `authorize` i reguły environments, których nie widać z repo.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Build, lint, format check i lokalne testy dla PR bez sekretów | 11 kroków workflow, wszystkie wykonane lokalnie bez providerów | ✅ |
| Oddzielone powiadomienia wymagające uprawnień | Slack i testy forkowe zostają w `ci.yml`; nowy job nie przyjmuje żadnych sekretów | ✅ |
| Przejrzana ścieżka PR z forka i uprawnienia jobów | sekcja „The privileged workflow" w `docs/ci.md` | ✅ |
| Brak wykonywania kodu PR z sekretami (w nowym jobie) | `pull_request` + brak `secrets:`; fork dostaje token tylko do odczytu | ✅ |
| Przy zastanych błędach wskazać baseline zamiast ukrywać lub formatować repo | `format:check` jako `continue-on-error` + notatka i akapit w `docs/ci.md`; repo nie zostało sformatowane | ✅ |
| Ustawień GitHub environments nie sprawdzimy z VM | zapisane wprost jako zadanie dla administratora repozytorium | ⚠️ poza środowiskiem |

## Odstępstwa od planu

- Nie zmieniono `ci.yml` ani `smart-contracts-build.yml`. Migracja
  uprzywilejowanego workflow to zakres T44; tutaj powstaje ścieżka bez sekretów,
  która nie psuje istniejących kontroli.

## Follow-upy (poza zakresem, NIE zrobione)

- Potwierdzenie reguł ochrony environment `external` w ustawieniach GitHub
  (nie da się z repo ani z VM).
- Zamknięcie baseline'u formatowania osobną zmianą, żeby `format:check` mógł
  zacząć blokować.
- Job forkowy z RPC — T44; kontrola aktualności dokumentów i artefaktów — T45.
