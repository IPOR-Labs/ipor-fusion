# T30 — Sprawdzenie stanu utworzonego vaulta

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T29 (ready-for-commit)

## Zakres wykonany

Wspólny verifier stanu utworzonego vaulta, podłączony do wyniku symulacji.

- `tools/lib/vault-state.mjs` — `readVaultState` (odczyty przez `cast call`) i
  `checkVaultState` (czyste reguły) oraz `verifyVaultState` łączące oba. 29
  kontroli: kod komponentów, tożsamość (asset, nazwa, symbol, decimals),
  powiązania (access/price/rewards manager, withdraw i fee manager, vault base,
  okno wypłat) oraz uprawnienia i opłaty (OWNER_ROLE i delay, redemption delay,
  pakiet DAO, konta opłat i stawki).
- `tools/simulate-vault.mjs` — po udanym utworzeniu uruchamia verifier; raport
  ma `result.verification` (wynik, lista kontroli, odczyty), a status `success`
  zmienia się na `unverified`, gdy któraś kontrola nie przejdzie.
- `test/fixtures/vault-state/created-vault.json` — realne odczyty vaulta
  utworzonego przez niezmienioną fabrykę na bloku 25937526.
- `tools/test-vault-state.mjs` — 21 testów reguł bez sieci.
- `docs/vaults.md` — sekcja „Verifying the created vault".
- `package.json` — `vault:state:test`.

## Kroki

1. **Rozdzielenie odczytu od reguł** — czysta funkcja `checkVaultState` pozwala testować „celowo błędne oczekiwania" offline; odczyt zostaje cienką warstwą.
2. **Podłączenie do symulacji** — pierwszy przebieg dał `unverified` z dwoma błędami (`fees.vaultManagementAccount`, `fees.vaultPerformanceAccount`); odczyt kodu (`FeeManager.MANAGEMENT_FEE_ACCOUNT`) pokazał, że vault płaci do kont opłat, nie do managera. Reguła została poprawiona na porównanie z tym, co raportuje fee manager. Verifier wykrył więc błędne oczekiwanie zanim trafiło do dokumentacji.
3. **Przebieg poprawny** — `node tools/simulate-vault.mjs --plan <plan>` → `success`, `verification.ok true`, 29 kontroli.
4. **Testy reguł** — `npm run vault:state:test` → 21/21, lista w [`runs.txt`](runs.txt).
5. **Test integracyjny** — `npm run vault:simulate:test` → 7/7, w tym asercja `verification.ok`.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Wspólny verifier adresów, powiązań, ownera, ról, underlying, decimals, opłat, oracle i parametrów wypłat | 29 kontroli w `checkVaultState`; brakującym elementem jest tylko konfiguracja fuse'ów/substrates, której świeży vault nie ma | ✅ |
| Podłączony do wyniku symulacji | `result.verification` w raporcie `vault:simulate`, status `unverified` przy błędzie | ✅ |
| Poprawny vault przechodzi | realny przebieg na forku: 29/29 | ✅ |
| Celowo błędne oczekiwania nie przechodzą | 19 scenariuszy, każdy z dokładną listą niezaliczonych kontroli | ✅ |
| Samo istnienie adresu nie jest dowodem | test „existing addresses alone are not accepted as proof": kontrole istnienia przechodzą, 5 kontroli powiązań nie | ✅ |

## Odstępstwa od planu

- Wartości powiązań porównywane są z innymi odczytami z tego samego łańcucha
  (np. okno wypłat z fabryki), a nie ze stałymi w kodzie narzędzia — dzięki temu
  inna konfiguracja wdrożenia nie wymaga edycji reguł.
- „Parametry wypłat" ograniczono do właściciela okna i powiązania z vaultem;
  opłaty za wypłatę/żądanie są zerowe w świeżym vaulcie i sprawdzane dopiero po
  konfiguracji strategii (T35/T36).

## Follow-upy (poza zakresem, NIE zrobione)

- Verifier nie sprawdza fuse'ów, substrates, limitów ani pre-hooków — świeżo
  utworzony vault ich nie ma; rozszerzenie należy do T35/T36.
- Odczyty w raporcie symulacji rosną wraz z liczbą kontroli; jeśli raport ma
  trafiać do CI, warto oddzielić `--verbose`.
