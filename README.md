# IPOR Fusion

IPOR Fusion is a yield optimization framework for automated execution of smart asset management on-chain, saving users
time and effort. It is an unopinionated and customizable infrastructure fund managers can use to deploy assets on-chain
while implementing custom algorithms off-chain.

## Technical Overview

More technical information can be found
here: [What is IPOR Fusion? A Technical Overview](https://blog.ipor.io/what-is-ipor-fusion-a-technical-overview-114ccd67dfcf)

## Installation

To install the dependencies for this project:

```bash
npm install
```

This will install all the required Node.js packages listed in [package.json](./package.json).

## Smart Contract Development

This project uses Foundry for Ethereum smart contract development. To get started with Foundry:

1. Install Foundry by following [Foundry's installation guide](https://getfoundry.sh/).
2. Build the smart contracts using:

```bash
forge build
```

## Testing

To run smart contract tests, you need to set up a `.env` file with the required environment variables.

### Environment Variables
An example `.env` file is in [.env.example](./.env.example). Copy this file to `.env` and fill in the required values.

- `ETHEREUM_PROVIDER_URL` - Ethereum provider URL
- `ARBITRUM_PROVIDER_URL` - Arbitrum provider URL
- `BASE_PROVIDER_URL` - Base provider URL
- `TAC_PROVIDER_URL` - TAC provider URL
- `INK_PROVIDER_URL` - Ink provider URL

Test smart contracts using:

```bash
forge test -vvv --ffi
```

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


