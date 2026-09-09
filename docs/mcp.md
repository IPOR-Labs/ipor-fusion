# Reading the deployment registry through MCP

An agent that already speaks MCP can read this repository's registry without
shelling out. Two tools exist, both read-only, both calling the same code as the
CLI.

## What the existing server already does

The IPOR Fusion MCP server (`ipor-fusion-dev`, SDK `3.6.7`) is the **discovery**
source and stays that way. It answers:

- `fusion_address_lookup` / `fusion_address_names` — which addresses exist, by
  name or address, per chain;
- `contract_abi` / `contract_source` — the verified explorer ABI and source for
  an address;
- vault, keeper and market queries.

What it does not answer is this repository's evidence: which deployments **we**
registered, at which block they were verified, against which ABI file and hash,
and which compatibility test proves the deployment can be used. That evidence
lives in `deployments/`, and it is the reason the two tools below exist. They add
no registry of their own — they read the same JSON a reviewer reads.

## The two tools

```bash
npm run mcp:deployments      # stdio MCP server
```

Client configuration is one entry, for example:

```json
{
    "mcpServers": {
        "ipor-fusion-deployments": {
            "command": "npm",
            "args": ["run", "--silent", "mcp:deployments"],
            "cwd": "/path/to/ipor-fusion"
        }
    }
}
```

### `list_deployments`

Optional `chainId` and `status`. Returns each registered deployment with its
kind, status, address, implementation, reported version, supported operations and
its full `verification` record — so a caller sees the evidence level, not just an
address.

### `inspect_factory`

Requires `chainId`, `deploymentId`, `block` and `caller`. It runs
`tools/inspect-factory.mjs`, the same inspector `npm run factory:inspect` runs,
and returns its JSON unchanged. Its named failures (`RPC_UNAVAILABLE`,
`CHAIN_MISMATCH`, `NO_CODE`, `IMPLEMENTATION_MISMATCH`,
`UNSUPPORTED_FACTORY_VERSION`) come back as the tool's error text.

`caller` is required for the same reason it is required on the CLI: the factory
resolves fee packages by `msg.sender`, so an inspection without a real caller
answers a different question.

## What it cannot do

There is no tool that signs, sends, plans an execution or writes a file. Planning,
simulation, configuration and execution stay on the CLI, where the scope file,
the preflight and the journal are — see [vaults.md](vaults.md). A test asserts
that the tool list contains exactly `list_deployments` and `inspect_factory`.

The provider URL never appears in a response: the inspector reports the variable
name only, and a test checks the URL is absent from the tool output.

## Agreement with the CLI

The acceptance rule for these tools is that the same input gives the same answer
on both paths. `npm run mcp:deployments:test` runs the MCP call and the CLI for
the same chain, deployment, block and caller, and compares the parsed JSON
structurally — not a snapshot, the actual objects.
