# IPOR Fusion

[![DeepWiki](https://img.shields.io/badge/DeepWiki-IPOR--Labs%2Fipor--fusion-blue.svg?logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACwAAAAyCAYAAAAnWDnqAAAAAXNSR0IArs4c6QAAA05JREFUaEPtmUtyEzEQhtWTQyQLHNak2AB7ZnyXZMEjXMGeK/AIi+QuHrMnbChYY7MIh8g01fJoopFb0uhhEqqcbWTp06/uv1saEDv4O3n3dV60RfP947Mm9/SQc0ICFQgzfc4CYZoTPAswgSJCCUJUnAAoRHOAUOcATwbmVLWdGoH//PB8mnKqScAhsD0kYP3j/Yt5LPQe2KvcXmGvRHcDnpxfL2zOYJ1mFwrryWTz0advv1Ut4CJgf5uhDuDj5eUcAUoahrdY/56ebRWeraTjMt/00Sh3UDtjgHtQNHwcRGOC98BJEAEymycmYcWwOprTgcB6VZ5JK5TAJ+fXGLBm3FDAmn6oPPjR4rKCAoJCal2eAiQp2x0vxTPB3ALO2CRkwmDy5WohzBDwSEFKRwPbknEggCPB/imwrycgxX2NzoMCHhPkDwqYMr9tRcP5qNrMZHkVnOjRMWwLCcr8ohBVb1OMjxLwGCvjTikrsBOiA6fNyCrm8V1rP93iVPpwaE+gO0SsWmPiXB+jikdf6SizrT5qKasx5j8ABbHpFTx+vFXp9EnYQmLx02h1QTTrl6eDqxLnGjporxl3NL3agEvXdT0WmEost648sQOYAeJS9Q7bfUVoMGnjo4AZdUMQku50McDcMWcBPvr0SzbTAFDfvJqwLzgxwATnCgnp4wDl6Aa+Ax283gghmj+vj7feE2KBBRMW3FzOpLOADl0Isb5587h/U4gGvkt5v60Z1VLG8BhYjbzRwyQZemwAd6cCR5/XFWLYZRIMpX39AR0tjaGGiGzLVyhse5C9RKC6ai42ppWPKiBagOvaYk8lO7DajerabOZP46Lby5wKjw1HCRx7p9sVMOWGzb/vA1hwiWc6jm3MvQDTogQkiqIhJV0nBQBTU+3okKCFDy9WwferkHjtxib7t3xIUQtHxnIwtx4mpg26/HfwVNVDb4oI9RHmx5WGelRVlrtiw43zboCLaxv46AZeB3IlTkwouebTr1y2NjSpHz68WNFjHvupy3q8TFn3Hos2IAk4Ju5dCo8B3wP7VPr/FGaKiG+T+v+TQqIrOqMTL1VdWV1DdmcbO8KXBz6esmYWYKPwDL5b5FA1a0hwapHiom0r/cKaoqr+27/XcrS5UwSMbQAAAABJRU5ErkJggg==)](https://deepwiki.com/IPOR-Labs/ipor-fusion)

IPOR Fusion is a yield optimization framework for automated execution of smart asset management on-chain, saving users
time and effort. It is an unopinionated and customizable infrastructure fund managers can use to deploy assets on-chain
while implementing custom algorithms off-chain.

Repository guidance for contributors and coding agents is in [AGENTS.md](./AGENTS.md).

## Technical Overview

More technical information can be found
here: [What is IPOR Fusion? A Technical Overview](https://blog.ipor.io/what-is-ipor-fusion-a-technical-overview-114ccd67dfcf)

## Installation

Initialize the Git submodules at the commits recorded by this repository, then install the exact Node.js dependency tree
from [package-lock.json](./package-lock.json):

```bash
git submodule update --init --recursive
npm ci
```

Run the submodule command again if a checkout is missing `lib/forge-std`, `lib/foundry-random`, or one of their nested
submodules. `npm ci` checks that [package.json](./package.json) and the lockfile agree and installs without updating the
locked dependency versions.

## Smart Contract Development

This project uses Foundry `v1.7.1` for Ethereum smart contract development. To get started with Foundry:

1. Install Foundry by following [Foundry's installation guide](https://getfoundry.sh/).
2. Install the repository's validated Foundry release:

```bash
foundryup --install v1.7.1
forge --version
```

The version output should start with `forge Version: 1.7.1`. Use this pinned release locally so builds and tests match CI.

3. Build the smart contracts using:

```bash
forge build
```

### Formatting

Check Solidity formatting without changing files:

```bash
npm run format:check
```

To apply formatting to Solidity contracts and tests as a separate operation, run `npm run prettier:all`.

## Testing

To run smart contract tests, you need to set up a `.env` file with the required environment variables.

### Environment Variables

Copy the tracked [.env.example](./.env.example) file to `.env` and fill in the required values:

```bash
cp .env.example .env
```

- `ETHEREUM_PROVIDER_URL` - Ethereum provider URL
- `ARBITRUM_PROVIDER_URL` - Arbitrum provider URL
- `BASE_PROVIDER_URL` - Base provider URL
- `TAC_PROVIDER_URL` - TAC provider URL
- `INK_PROVIDER_URL` - Ink provider URL

Fork tests select pinned historical blocks. Each provider must therefore support archive state for the blocks used by the
tests; an endpoint that serves only recent state can be reachable and still fail a fork test. Keep credentials in the
ignored `.env` file and never commit them.

Test smart contracts using:

```bash
forge test -vvv --ffi
```

Run the classified local factory suite without RPC credentials, FFI or
filesystem permissions:

```bash
npm run test:unit
```

The command validates the suite catalog first and exits non-zero when the
selection is empty or Forge fails. Its current coverage is documented in
[`docs/testing.md`](./docs/testing.md).

Run the classified Ethereum factory fork suites at an explicit historical
block:

```bash
npm run test:fork -- --chain 1 --suite factory --block 23831825
```

This requires `ETHEREUM_PROVIDER_URL` in the ignored `.env` file. The runner
passes the requested block into each fixture; it does not silently use the
fixture's former hardcoded value.

Diagnose the local checkout without making network calls:

```bash
npm run agent:doctor
npm run agent:doctor -- --json
npm run agent:doctor -- --rpc --chain 1 --block 23831825
```

The command checks tool versions, installed dependencies, submodule commits and
which RPC variable names are present. Missing optional RPC variables are
warnings in this offline mode. Values from the environment and `.env` are never
printed. The opt-in `--rpc` mode additionally verifies the provider chain ID and
contract code at the requested historical block.

Select and run the classified suites affected by a branch:

```bash
npm run test:affected -- --base origin/main
npm run test:affected -- --base origin/main --json
```

JSON mode is a non-executing plan. The default mode runs the selected local and
fork suites and returns non-zero if the required RPC is absent.

## Pre-commit hooks

### requirements

- Python 3.11.6
- Node.js 20.17.0

### install pre-commit

use instruction from https://pre-commit.com/

#### install pre-commit

- `pip install pre-commit`
- `pre-commit install`

## Workflows

This repository includes several GitHub Actions workflows located in `.github/workflows/`:

- **CI Workflow** (`ci.yml`): Runs continuous integration tasks.
- **CD Workflow** (`cd.yml`): Manages continuous deployment processes.

## License

For more details, see the [LICENSE](./LICENSE) file.
