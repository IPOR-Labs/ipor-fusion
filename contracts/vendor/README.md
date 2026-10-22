# Vendored transport dependencies

This directory holds third-party Solidity that the crosschain POC compiles against directly (rather than
via npm) so the build is hermetic and the exact transport bytecode is reviewable in-tree
(`CROSSCHAIN_AUDIT_FIX_PLAN` §7). Every file here is an unmodified upstream copy **except the single local
modification listed under [Local modifications](#local-modifications)**; the only IPOR-authored file is
`VendorCompileCheck.sol` (a compile-only shim, BUSL-1.1). No LayerZero codec, peer-authentication or
option-merging file was edited; the one change is a `virtual` keyword on an owner-only setter.

## Local modifications

| File | Change | Why | Ticket |
| --- | --- | --- | --- |
| `layerzero/oapp/contracts/oapp/OAppCore.sol` | `setDelegate` made `virtual` (one keyword plus a comment line) | lets `StargateLzOAppBase` override and disable the owner's instant, un-timelocked endpoint-delegate change | IL-8557 / IL-8558 |

Everything else is verbatim. The manifest checksum of the modified file records the patched content.

- **Vendoring date:** 2026-07-16
- **Integrity manifest:** [`CHECKSUMS.sha256`](./CHECKSUMS.sha256) (sha256 of every vendored `.sol`)
- **Verification:** run [`./verify.sh`](./verify.sh) — recomputes every checksum, fails on any
  unrecorded add/remove/modify. It reported OK at the time of writing.

> **Exact upstream commit pinning — operator action required.** The manifest below fixes the *content*
> of each file reproducibly (a reviewer can diff any candidate upstream commit against these checksums).
> The precise upstream **tag + commit hash** each file was copied from must be filled in by the operator
> who performed the original vendoring: it cannot be reconstructed after the fact from the file contents
> alone. The `Upstream tag / commit` cells are therefore marked `TO PIN` and must be completed before this
> POC is treated as release-ready. This is the one part of §7 that remains open; see
> `CROSSCHAIN_AUDIT_FIX_REPORT.md`.

## Dependencies

### 1. LayerZero V2 — OApp / OFT + protocol interfaces + message-lib libs

- **Upstream repositories:**
  - OApp/OFT (`layerzero/oapp/**`): https://github.com/LayerZero-Labs/LayerZero-v2 (`packages/layerzero-v2/evm/oapp`), published as `@layerzerolabs/oapp-evm`.
  - Protocol interfaces (`layerzero/protocol/**`): same monorepo, `packages/layerzero-v2/evm/protocol`, published as `@layerzerolabs/lz-evm-protocol-v2`.
  - Message-lib libs (`layerzero/messagelib/**`, `layerzero/protocol/.../messagelib/**`): same monorepo, `packages/layerzero-v2/evm/messagelib`, published as `@layerzerolabs/lz-evm-messagelib-v2`.
- **Remappings (`foundry.toml`):**
  `@layerzerolabs/lz-evm-protocol-v2/contracts/` → `contracts/vendor/layerzero/protocol/contracts/`;
  `@layerzerolabs/lz-evm-oapp-v2/contracts/` → `contracts/vendor/layerzero/oapp/contracts/`;
  `@layerzerolabs/lz-evm-messagelib-v2/contracts/` → `contracts/vendor/layerzero/messagelib/contracts/`.
- **Licenses:** dual — most interfaces/OApp files are **MIT**; the LayerZero-authored codec/option libs
  (`DVNOptions.sol`, `CalldataBytesLib.sol`, `ExecutorOptions.sol`) are **LZBL-1.2**. See per-file SPDX
  headers and [`licenses/LayerZero-LICENSE.md`](./licenses/LayerZero-LICENSE.md).
- **Upstream tag / commit:** `TO PIN`.
- **Local modifications:** one — `layerzero/oapp/contracts/oapp/OAppCore.sol`: `setDelegate` made `virtual`
  (IL-8557 / IL-8558) so the Stargate OApp base can disable it; all other files are verbatim copies.

### 2. Stargate V2 — `IStargate` interface

- **Upstream repository:** https://github.com/stargate-protocol/stargate-v2 (`packages/stg-evm-v2/src`),
  published as `@stargatefinance/stg-evm-v2`.
- **Remapping:** `@stargatefinance/stg-evm-v2/` → `contracts/vendor/stargate/`.
- **License:** **BUSL-1.1** (Stargate). See [`licenses/Stargate-LICENSE.md`](./licenses/Stargate-LICENSE.md).
- **Upstream tag / commit:** `TO PIN`.
- **Local modifications:** none (interface only).

### 3. Solady — `CREATE3`

- **Upstream repository:** https://github.com/Vectorized/solady (`src/utils/CREATE3.sol`), published as `solady`.
- **Remapping:** `solady/` → `contracts/vendor/solady/src/`.
- **License:** **MIT**. See [`licenses/Solady-LICENSE.txt`](./licenses/Solady-LICENSE.txt).
- **Upstream tag / commit:** `TO PIN`.
- **Local modifications:** none.

### 4. solidity-bytes-utils — `BytesLib`

- **Upstream repository:** https://github.com/GNSPS/solidity-bytes-utils (`contracts/BytesLib.sol`),
  published as `solidity-bytes-utils`.
- **Remapping:** `solidity-bytes-utils/` → `contracts/vendor/solidity-bytes-utils/`.
- **License:** **Unlicense** (public domain). See [`licenses/solidity-bytes-utils-LICENSE`](./licenses/solidity-bytes-utils-LICENSE).
- **Upstream tag / commit:** `TO PIN`.
- **Local modifications:** none.

## File inventory (license + solidity pragma)

| File | License | pragma |
| --- | --- | --- |
| `layerzero/messagelib/contracts/uln/libs/DVNOptions.sol` | LZBL-1.2 | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/OApp.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/OAppCore.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/OAppReceiver.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/OAppSender.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/interfaces/IOAppComposer.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/interfaces/IOAppCore.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/interfaces/IOAppOptionsType3.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/interfaces/IOAppReceiver.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/libs/OAppOptionsType3.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oapp/libs/OptionsBuilder.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oft/interfaces/IOFT.sol` | MIT | ^0.8.20 |
| `layerzero/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol` | MIT | ^0.8.20 |
| `layerzero/protocol/contracts/interfaces/*.sol` | MIT | >=0.8.0 |
| `layerzero/protocol/contracts/libs/CalldataBytesLib.sol` | LZBL-1.2 | ^0.8.20 |
| `layerzero/protocol/contracts/messagelib/libs/BitMaps.sol` | MIT | ^0.8.20 |
| `layerzero/protocol/contracts/messagelib/libs/ExecutorOptions.sol` | LZBL-1.2 | ^0.8.20 |
| `solady/src/utils/CREATE3.sol` | MIT | ^0.8.4 |
| `solidity-bytes-utils/contracts/BytesLib.sol` | Unlicense | >=0.8.0 <0.9.0 |
| `stargate/src/interfaces/IStargate.sol` | BUSL-1.1 | ^0.8.0 |

`VendorCompileCheck.sol` (IPOR-authored, BUSL-1.1, pragma 0.8.30) is intentionally excluded from the
manifest: it is a local compile shim, not vendored code.
