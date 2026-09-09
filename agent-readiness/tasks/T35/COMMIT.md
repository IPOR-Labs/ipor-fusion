# T35 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T35 configure the ERC4626 pilot strategy

Add vault:configure, which applies one catalogued integration to one created
vault on a development fork: it grants the operator roles, registers the action
and balance fuse, grants exactly the listed ERC4626 substrates and sets and
activates the market limit, then reads the configuration back from the vault.

Wrong inputs are named refusals: an unknown catalog entry, another market, a fuse
the catalog never observed, a substrate in another asset, an unpriceable asset, a
missing role, or an endpoint that is not a fork.

Verified on a fork: the configured operators configure a freshly created vault,
a non-owner is refused with MISSING_ROLE and an sDAI substrate with
SUBSTRATE_ASSET_MISMATCH.
```

Ten sam tekst jest w `agent-readiness/tasks/T35/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T35 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T35 → ready-for-commit |
| `agent-readiness/tasks/T35/*` | nowe — LOG, COMMIT, komunikat, runs |
| `config/strategies/strategy-configuration.schema.json` | nowy — schemat wejścia |
| `config/strategies/erc4626-usdc.json` | nowy — przykład pilotażu |
| `tools/configure-strategy.mjs` | nowy — `vault:configure` |
| `tools/test-configure-strategy.mjs` | nowy — 3 testy |
| `docs/vaults.md` | zmieniony — sekcja o konfiguracji strategii |
| `package.json` | zmieniony — `vault:configure`, `vault:configure:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T34. `docs/vaults.md` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T35/
git add config/strategies/ tools/configure-strategy.mjs tools/test-configure-strategy.mjs
git add docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T35/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T35 na `committed <hash>`.
