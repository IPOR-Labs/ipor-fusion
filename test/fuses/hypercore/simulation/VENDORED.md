# Vendored: hyper-evm-lib offline HyperCore simulator

- **Source**: https://github.com/hyperliquid-dev/hyper-evm-lib
- **Commit**: `4eb7ab044d0a368e0c01ec5b38d5ea48a3e3b427` (2026-06-24)
- **License**: MIT (Copyright (c) 2025 Obsidian Audits) — see `LICENSE-hyper-evm-lib`

Vendored so `test/fuses/hypercore/HyperCoreFlowSimulationTest.t.sol` can exercise the HyperCore
fuses end-to-end against an offline, in-process HyperCore precompile/CoreWriter simulator instead
of a live RPC fork.

## Files copied (path in this dir ← upstream path)

- `CoreSimulatorLib.sol` ← `test/simulation/CoreSimulatorLib.sol`
- `HyperCore.sol` ← `test/simulation/HyperCore.sol`
- `PrecompileSim.sol` ← `test/simulation/PrecompileSim.sol` (**modified**, see below)
- `CoreWriterSim.sol` ← `test/simulation/CoreWriterSim.sol` (**modified**, see below)
- `hyper-core/CoreExecution.sol` ← `test/simulation/hyper-core/CoreExecution.sol` (**modified**)
- `hyper-core/CoreView.sol` ← `test/simulation/hyper-core/CoreView.sol`
- `hyper-core/CoreState.sol` ← `test/simulation/hyper-core/CoreState.sol` (**modified**)
- `src/PrecompileLib.sol` ← `src/PrecompileLib.sol`
- `src/CoreWriterLib.sol` ← `src/CoreWriterLib.sol`
- `src/common/HLConstants.sol` ← `src/common/HLConstants.sol`
- `src/common/HLConversions.sol` ← `src/common/HLConversions.sol`
- `src/registry/TokenRegistry.sol` ← `src/registry/TokenRegistry.sol`
- `src/interfaces/ITokenRegistry.sol` ← `src/interfaces/ITokenRegistry.sol`
- `src/interfaces/ICoreWriter.sol` ← `src/interfaces/ICoreWriter.sol`
- `src/interfaces/ICoreDepositWallet.sol` ← `src/interfaces/ICoreDepositWallet.sol`
- `utils/RealL1Read.sol` ← `test/utils/RealL1Read.sol` (kept for compilation only — its RPC-backed
  functions are fork-only and are not exercised by the offline flow test; see below)

Not vendored: `test/utils/L1Read.sol`, `test/utils/PrecompileSimulator.sol`,
`test/utils/HypeTradingContract.sol`, `src/examples/*`, `src/registry/README.md`, and the upstream
`test/unit-tests/*`, `test/BaseSimulatorTest.sol`, `test/PrecompileLibTests.t.sol` — none are
needed by the offline path this repo's fuses exercise.

## Local modifications (not upstream)

1. **Import path rewrites only** — all `"../../src/..."` / `"../../../src/..."` / `"../../utils/..."`
   relative imports were rewritten to match this directory's flatter layout
   (`simulation/`, `simulation/hyper-core/`, `simulation/src/**`, `simulation/utils/`). No logic
   changed.

2. **`PrecompileSim.sol` — offline L1 block number precompile (0x809).** Upstream falls through to
   `_makeRpcCall` (a live `vm.rpc` call) for the L1 block number precompile, because at this
   snapshot offline mode has no local handler for it. `HyperCorePendingLib.sol`'s TIMING
   settlement mode (`contracts/fuses/hypercore/lib/HyperCorePendingLib.sol:85,88,121,170`) reads this
   precompile via `HyperCoreLib.l1BlockNumber()` to gate settlement on "strictly after the L1 block
   the action was enqueued in" — this must resolve without an RPC for the offline test to run.
   Added a local branch returning `abi.encode(uint64(block.number))`, since
   `CoreSimulatorLib.nextBlock()` already does `vm.roll(block.number + 1)` on every simulated block,
   giving the same "strictly increasing per block" semantics a real L1 block number would.

3. **`PrecompileSim.sol` — removed the empty `receive()`.** Upstream declares
   `receive() external payable {}` alongside `fallback(bytes calldata)`. Every call into this contract
   is a `staticcall` (value is always 0; see `HyperCoreLib._staticRead`), but Solidity's call dispatch
   routes an EMPTY-calldata call to `receive()` when one is declared, regardless of value --
   and `HyperCoreLib.l1BlockNumber()` staticcalls 0x809 with empty calldata
   (`_staticRead(L1_BLOCK_NUMBER_PRECOMPILE, bytes(""))`). With `receive()` present that call never
   reached the `fallback` branch (including the local L1-block-number handler from modification 2
   above) and returned empty data, reverting with `HyperCorePrecompileFailed`. Removed the `receive()`
   since nothing ever sends value to these precompile addresses.

4. **`hyper-core/CoreExecution.sol` — activate-on-first-deposit now sets `_initializedAccounts` /
   `_initializedDexBalance[DEFAULT_PERP_DEX]`.** `executeTokenTransfer`'s first-deposit activation
   branch (for a quote token, e.g. USDC) sets `_accounts[from].activated = true` and
   `_initializedSpotBalance[from][token] = true` directly, without going through
   `_initializeAccount(from, true)`. That left `_initializedAccounts[from]` and
   `_initializedDexBalance[from][HLConstants.DEFAULT_PERP_DEX]` false even though the account was
   already funded and activated. The vault's *next* touch of the default perp dex -- either
   `executePerpLimitOrder`'s `initAccountWithPerp` modifier (which calls `_initializeAccount(from)`,
   force=false) or its own `_initializeDex(sender, dex)` call -- would then see "not yet initialized"
   and unconditionally overwrite `perpBalance[DEFAULT_PERP_DEX]` from a freshly computed
   `withdrawable()` (backed by an unrefreshed, still-zero `marginSummary`), silently discarding any
   margin already moved in by a prior `executeUsdClassTransfer`. Symptom in this test: the IOC short
   was dropped with `HyperCore.executeRawAction` reverting "insufficient perp balance for fee" (visible
   once `CoreSimulatorLib.setRevertOnFailure(true)` is set in the test; `CoreWriterSim` otherwise drops
   a reverted queued action silently). Fixed by setting both flags in that activation branch, matching
   what `_initializeAccount(force=true)` does.

5. **`Heap.Uint256Heap` — local minimal replacement (`oz-ext/Heap.sol`).** `CoreWriterSim.sol`,
   `hyper-core/CoreState.sol` and `hyper-core/CoreExecution.sol` import
   `@openzeppelin/contracts/utils/structs/Heap.sol`, added in OpenZeppelin Contracts v5.1. This
   repo pins `@openzeppelin/contracts@5.0.2` (`node_modules/@openzeppelin/contracts`), which does
   not have that file, and per repo convention `foundry.toml` remappings were not touched. Only
   `CoreWriterSim.sol` actually calls heap methods (`insert`, `length`, `peek`, `pop`, used to order
   queued CoreWriter actions); `CoreState.sol`/`CoreExecution.sol` declare
   `using Heap for Heap.Uint256Heap;` but never instantiate a heap variable. Added
   `oz-ext/Heap.sol`, a ~50-line local library implementing just that subset as a plain
   array-backed binary min-heap, and repointed the three imports at it instead of vendoring the
   rest of the OZ 5.1 dependency graph (`Comparators`, `Panic`, `Arrays`, `SlotDerivation`, ...).
   Behavior (a min-heap ordered by the queued action's `uint256` key) is equivalent for this
   subset.

6. **`hyper-core/CoreExecution.sol` / `hyper-core/CoreView.sol` / `CoreSimulatorLib.sol` — oracle price control
   (IL-8534).** Added `setOraclePx(perp, px)` (and the `CoreSimulatorLib.setOraclePx` wrapper) so tests can pin the
   Core oracle price independently of the mark price. Offline, an oracle price that was never pinned reads as the
   current mark price (upstream returned 0), so tests that only move the mark keep a zero mark/oracle deviation
   for the valuation band `HyperCoreValuationLib` enforces.

## Known gaps / not exercised offline

- `utils/RealL1Read.sol` is fork/RPC-only. It is imported by `CoreState.sol` (`registerTokenInfo(uint64)`
  single-arg override, `RealL1Read.accountMarginSummary` in account (re)loading) and by
  `CoreExecution.sol`/`CoreView.sol`, but those RPC-backed paths only fire for **unregistered**
  tokens/accounts. `CoreSimulatorLib.init()` in offline mode (`isForkActive() == false`) seeds
  USDC (0), HYPE (150) and USDT0 (268) directly via `registerTokenInfo(index, TokenInfo)`
  (2-arg), so `registerTokenInfo(uint64)` (1-arg, which calls `RealL1Read.tokenInfo`) short-circuits
  and returns early for those tokens without ever calling out. The offline flow test only touches
  USDC (0) and one perp, so `RealL1Read`'s RPC path is never invoked; it is vendored solely to
  satisfy the compiler.
- `CoreSimulatorLib._deployTokenRegistryAndCoreTokens()` seeds USDC (token 0) with
  `evmContract: address(0)` (no linked EVM ERC20) by default, since upstream expects
  `TokenRegistry`/on-chain metadata to supply the real HyperEVM USDC address on a fork. The
  offline flow test re-registers token 0 via `HyperCore.registerTokenInfo(0, TokenInfo)` after
  `CoreSimulatorLib.init()`, pointing `evmContract` at a local `SimCoreDepositWallet` shim (see
  "Local additions" below) wrapping the vault's own underlying test USDC ERC20, matching
  `HyperCoreDepositFuse`'s CoreDepositWallet routing for token 0 (the fuse calls `depositFor` on
  `tokenInfo(0).evmContract` directly; it no longer transfers USDC to the token's system address,
  so the old `Transfer`-log-scan detection in `CoreSimulatorLib.nextBlock()` does not fire for
  token 0 and is bypassed entirely by the shim crediting Core spot directly).

## Local additions (not vendored, not upstream)

- **`SimCoreDepositWallet.sol`** — a local test double for Hyperliquid/Circle's real
  `CoreDepositWallet` (the contract `tokenInfo(0).evmContract` points at on networks where USDC is
  CCTP-native), added because the vendored simulator has no built-in model of it. Implements
  `token()`/`paused()`/`deposit()`/`depositFor()` per `contracts/fuses/hypercore/ICoreDepositWallet.sol`
  and `HyperCoreFlowSimulationTest.setUp()` registers it as `tokenInfo(0).evmContract`.
  - **Deposit (EVM → Core) leg**: `depositFor(recipient, amount, destinationDex)` pulls `amount` of
    the real underlying USDC via `transferFrom(msg.sender, address(this), amount)` (mirroring the
    real wallet), then calls `HyperCore.executeTokenTransfer(address(0), tokenIndex, recipient,
    amount)` directly — the exact same entrypoint `CoreSimulatorLib.nextBlock()`'s Transfer-log scan
    uses for the generic (non-wallet) token path — so activation-fee handling and wei-decimal
    conversion for the wallet path stay bit-for-bit identical to every other granted token's deposit.
  - **Withdrawal (Core → EVM) leg, unforeseen interaction found while wiring this in**: the vendored
    `hyper-core/CoreExecution.sol`'s `executeSpotSend` (used by `HyperCoreSendFuse`'s Core→EVM
    `sendAsset` step, exercised by this flow test's final phase) treats `tokenInfo(token).evmContract`
    as a plain ERC20 for the *return* leg: `deal(evmContract, systemAddress,
    IERC20(evmContract).balanceOf(systemAddress) + transferAmount)` then
    `IERC20(evmContract).safeTransfer(sender, transferAmount)` (lines ~423-431). Once
    `tokenInfo(0).evmContract` became this wallet instead of the real USDC contract, that call
    reverted with `unrecognized function selector 0x70a08231` (`balanceOf`) against the wallet.
    Rather than modify the vendored `CoreExecution.sol` (production-adjacent, shared code) to special
    -case token 0, `SimCoreDepositWallet` itself now also exposes a minimal, self-contained
    `balanceOf(address)`/`transfer(address,uint256)` pair backed by its own storage mapping
    (`_withdrawBalances`, unrelated to the real USDC it holds from deposits): `deal()` locates and
    writes that mapping's slot as usual, and `transfer()` then mints the equivalent amount of real
    `token()` USDC to the recipient via the mock USDC's open `mint(address,uint256)` (see
    `test/fuses/hypercore/HyperCoreTestHelper.sol`'s `HyperCoreMockUsdc`), so the vault still ends up
    with real, spendable USDC after the round trip. This is purely a simulator-side shim; it has no
    bearing on `HyperCoreDepositFuse`/`HyperCoreSendFuse`, which never call `balanceOf`/`transfer` on
    the CoreDepositWallet — only `token()`, `paused()`, `deposit()`, `depositFor()` per
    `ICoreDepositWallet.sol`.
