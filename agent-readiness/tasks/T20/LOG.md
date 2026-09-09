# T20 — Ustalenie źródła adresów i wybór pilotażu

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `8fbf2d2`, branch `feature/agents-support`
- **Zależności:** T11 (`a92080a`)

## Zakres wykonany

- Zapytano `fusion_address_lookup` na serwerze `ipor-fusion-dev` / SDK
  `3.6.7` po nazwie `FusionFactory` dla chain ID 1 oraz osobno po pełnym
  adresie proxy.
- Lookup zwrócił dwa wpisy nazwowe: `IporFusionFactoryProxy`
  (`0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852`) i
  `IporFusionFactoryImpl`
  (`0xf19C1E9f6616F6056AF1e322A86fDaAaAf0263f5`). Exact address query
  zwrócił dokładnie jeden wpis proxy.
- Wybrano Ethereum mainnet jako pilot i zapisano status `candidate`, nie
  `verified`. Decyzję wspiera istniejący blok testowy `23831825` i udany
  historyczny probe T18, ale nie przypisano im mocniejszego znaczenia.
- `docs/deployments.md` rozdziela dane pochodzące z upstream lookupu,
  explorer source/ABI, przyszłego lokalnego manifestu i odczytów RPC.
- Nieznane tx/blok wdrożenia, proxy slot, runtime hashes i pochodzenie ABI są
  jawnie pozostawione do T21–T24.

## Weryfikacja

Surowe odpowiedzi bez sekretów zapisano w `address-lookup.json`. Sprawdzono
zgodność obu adresów z odpowiedzią narzędzia, obecność proxy w testach oraz
lokalne linki dokumentu.
