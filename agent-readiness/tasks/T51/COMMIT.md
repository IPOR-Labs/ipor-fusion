# T51 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(deployments): T51 support one additional network

Register the Base FusionFactory as a verified deployment on chain 8453: its own
manifest, its own ABI directory with provenance, a verification report pinned to
Base block 51000000, a factory_base test profile and a deployed-usage test that
creates a Base USDC vault through the unchanged proxy.

Nothing is shared with the Ethereum entry except the ABI file and the reported
version 8; the test asserts the two factory addresses differ, and the report
records that the Base implementation's bytecode is not the Ethereum one.

A selector probe found 42 of the ABI's 43 functions in the Base implementation;
the 43rd answers when called, and the report says so rather than reporting an
absence it did not verify.
```

Ten sam tekst jest w `agent-readiness/tasks/T51/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T51 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T51 → ready-for-commit |
| `agent-readiness/tasks/T51/*` | nowe — LOG, COMMIT, komunikat, runs |
| `deployments/8453/factories.json` | nowy — manifest sieci Base |
| `abi/fusion-factory-base-0x610152.../FusionFactory.abi.json` | nowy — ABI |
| `abi/fusion-factory-base-0x610152.../provenance.json` | nowy — pochodzenie i granice |
| `deployments/reports/base-fusion-factory-14557176-51000000.json` | nowy — raport |
| `test/deployed-factories/FusionFactoryBase.t.sol` | nowy — test |
| `foundry.toml` | zmieniony — profil `factory_base` |
| `config/test-suites.json` | zmieniony — suita dla chain 8453 |
| `config/test-suites.schema.json` | zmieniony — profil w enumie |
| `docs/deployments.md` | zmieniony — sekcja o Base |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T50. `config/test-suites.json` i `docs/deployments.md` są wspólne z
  wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T51/
git add deployments/8453/ abi/fusion-factory-base-0x610152a79be7f2aa3aa70520c9331c18fe8d33b7/
git add deployments/reports/base-fusion-factory-14557176-51000000.json
git add test/deployed-factories/FusionFactoryBase.t.sol foundry.toml
git add config/test-suites.json config/test-suites.schema.json docs/deployments.md
git status --short
git commit -F agent-readiness/tasks/T51/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T51 na `committed <hash>`.
