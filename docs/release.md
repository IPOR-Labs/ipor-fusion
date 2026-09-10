# Release checklist for the deployment registry

This page covers one kind of release: a change to what the repository claims
about a **deployment** — a new address, a new implementation behind an existing
proxy, a new ABI, or a new network. Contract releases have their own process;
this is about keeping the registry and the operational documentation true.

## Who owns what

[`CODEOWNERS`](../CODEOWNERS) requires review from the repository's owners for
`deployments/`, `abi/`, `catalog/`, `config/`, `docs/`, `tools/` and `.github/`.
Those are the paths where a wrong statement stops being a documentation bug and
starts being an operational one.

**Monitoring does not replace review.** The scheduled drift job
([ci.md](ci.md)) tells you that something changed on chain. It never updates a
manifest, never promotes an implementation, and its passing does not mean the
registry is correct — only that it still matches what a person confirmed the last
time.

## The checklist

Walk it in order. Each step names the command that produces the evidence.

1. **Find the addresses from a source, not from memory.**
   Query the deployment registry (`fusion_address_lookup`) and record the query,
   the answer and the date. Do not invent an address, and do not infer one from a
   test fixture.

2. **Bind an ABI to the deployed implementation.**
   Take the verified source/ABI for the implementation address, store it under
   `abi/<kind>-<network>-<implementation address>/` with a `provenance.json`, and
   check it:
   ```bash
   npm run validate:pilot-abi
   ```

3. **Register the entry as a candidate.**
   Add it to `deployments/<chain-id>/factories.json` with `status: "candidate"`
   and explicit `null`s for everything unknown:
   ```bash
   npm run validate:deployments
   ```

4. **Read the deployment at a block.**
   ```bash
   npm run factory:inspect -- --chain <id> --deployment <deployment-id> \
     --block <block> --caller <the caller that will be used>
   ```
   Fees are resolved by `msg.sender`, so inspect as the caller that will really
   send the transaction.

5. **Prove the deployment can be used, unchanged.**
   Add or extend a `deployed-usage` suite and classify it:
   ```bash
   npm run validate:test-suites
   npm run test:fork -- --chain <id> --suite <suite> --block <block>
   ```
   The test must not upgrade, etch, or grant itself anything.

6. **Write the verification report and promote to `verified`.**
   The report goes in `deployments/reports/` and carries the block and its hash,
   the toolchain versions, the inspector's own hash, the identity reads, the
   component code hashes and the compatibility test's result. Then set
   `status: "verified"` and fill every `verification` field:
   ```bash
   npm run validate:deployments      # refuses "verified" with a missing proof field
   ```

7. **Update the catalog if fuses or markets are involved.**
   ```bash
   npm run catalog:generate          # structural part, from the sources
   npm run validate:catalog
   ```
   Record what was **observed** on chain separately from what the checkout's
   source says; `matchesCurrentSource: false` is a normal, useful answer.

8. **Update the operational documentation.**
   [`deployments.md`](deployments.md) for the identity and evidence,
   [`vaults.md`](vaults.md) for anything the commands do differently, the recipes
   under [`recipes/`](recipes/) for the walked path, and
   [`invariants.md`](invariants.md) if the evidence for a property changed.
   ```bash
   npm run validate:docs
   ```

9. **Run the checks a reviewer will run.**
   ```bash
   npm run test:unit
   npm run test:fork -- --chain <id> --suite <suite> --block <block>
   npm run deployments:drift         # all verified entries: 0 unchanged, 1 drift, 2 incomplete
   ```

10. **Name the block and the date in the pull request.** A registry change that
    does not say which block it was verified at cannot be re-checked later.

## Keeping history

An upgrade does not delete the previous state:

- the previous verification report stays in `deployments/reports/`, because a
  historical test pinned to an older block must still be explainable;
- pinned fixture blocks are not re-pointed at a new block "to make CI green" — a
  regression test proves the old behaviour, a fresh-block job proves the current
  one;
- if a proxy's implementation changed, say so in `deployments.md` with both
  addresses and the blocks at which each was observed, as the pilot entry does
  for `23831825` and `25937526`.

## Walking it on the pilot

Every step above has already been executed once, for
`ethereum-fusion-factory-cd05909c`. The evidence it produced is the model for the
next one:

| Step | Artifact from the pilot |
| ---- | ------------------------ |
| 1–2  | [`abi/…/provenance.json`](../abi/fusion-factory-ethereum-0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5/provenance.json) |
| 3    | [`deployments/1/factories.json`](../deployments/1/factories.json) |
| 4–5  | the `deployed-factory` suites in [`config/test-suites.json`](../config/test-suites.json) |
| 6    | [`deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json`](../deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json) |
| 7    | [`catalog/fuses.json`](../catalog/fuses.json) |
| 8    | [`deployments.md`](deployments.md), [`recipes/create-vault.md`](recipes/create-vault.md) |
