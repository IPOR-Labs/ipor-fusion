# T50 — Jeden wariant wrappera

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T21 (`1d28609`), T24 (`562fea3`), T32 (ready-for-commit)

## Zakres wykonany

Jedna istniejąca fabryka wrappera: **WrappedPlasmaVaultFactory** (wariant zwykły)
na Ethereum.

- `abi/wrapped-plasma-vault-factory-ethereum-0x3f68a6…11f5/` — ABI (28 wpisów)
  wygenerowane z checkoutu i `provenance.json` mówiące wprost, że to nie jest ABI
  z explorera, jaki jest dowód zgodności i jakie są jego granice.
- `deployments/1/factories.json` — trzeci wpis, `kind: wrapped-vault-factory`.
- `deployments/reports/ethereum-wrapped-plasma-vault-factory-b17a9d70-25937526.json`
  — raport weryfikacji z sekcją `variant`.
- `test/deployed-factories/WrappedPlasmaVaultFactoryEthereum.t.sol` — 3 testy.
- `config/test-suites.json` — grupa `deployed-wrapped-vault-factory`.
- `docs/recipes/wrap-a-vault.md` (+ indeks) — recepta.

## Kroki

1. **Wybór wariantu** — lookup zwraca dwa warianty; wzięty zwykły, whitelistowy jawnie poza zakresem (zapis w provenance, raporcie, recepcie i teście).
2. **Zgodność ABI** — selektor `create(...)` `0x05b2bb5a` obecny w kodzie wdrożonej implementacji; ABI z checkoutu, pochodzenie i ograniczenia zapisane.
3. **Test** — wrapper na vaulcie utworzonym przez pilotażową fabrykę: powiązanie, tożsamość, właściciel, obie opłaty, uprawnienia i odrzucenia. Wyniki w [`runs.txt`](runs.txt).
4. **Rejestracja** — manifest + raport, walidatory przechodzą.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Jedna istniejąca fabryka wrappera: ABI/manifest, recepta i test utworzenia dla pilotażowego vaulta | cztery artefakty wyżej; test tworzy wrapper na vaulcie z pilotażowej fabryki | ✅ |
| Whitelist i zwykły wrapper jako różne warianty | osobne adresy; test asertuje, że to różne wdrożenia; recepta i raport mówią, że whitelist wymaga własnego wpisu i testu | ✅ |
| Test sprawdza powiązanie z vaultem | `PLASMA_VAULT()` i `asset()` porównane z vaultem | ✅ |
| …oraz uprawnienia/ograniczenia właściwe wariantowi | konfiguracja tylko dla właściciela wrappera (właściciel vaulta odrzucony), zerowy vault i opłata > 100% odrzucone | ✅ |

## Odstępstwa od planu

- ABI pochodzi z checkoutu, nie z zweryfikowanego źródła explorera (jak w T22 i
  T49). Powód i dowód zgodności są zapisane w `provenance.json`; wpis pozostaje
  `verified`, bo dowodem użycia jest przechodzący test na niezmienionym
  wdrożeniu, a nie samo ABI.

## Follow-upy (poza zakresem, NIE zrobione)

- Wariant whitelistowy: własne ABI, manifest, test i recepta.
- Ścieżka środków przez wrapper (deposit/withdraw i naliczanie opłat w czasie) —
  ten test sprawdza utworzenie, powiązanie i uprawnienia, nie cykl środków.
- Pobranie zweryfikowanego ABI implementacji z explorera, gdy będzie potrzebne
  poza samym `create`.
