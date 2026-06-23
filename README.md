<p style="text-align: center;width:100%"> <img src="https://pbs.twimg.com/profile_banners/1445781144125857796/1773687595"/></p>
<h1> <img style="text-align: center; height: 18px" src="https://user-images.githubusercontent.com/77558763/148961492-99d86d51-41a3-45a8-9af6-bdc1a85c722b.png"/> Curvance Protocol</h1>

Curvance protocol smart contracts. This repo uses Foundry for Solidity
builds/tests and pnpm for JavaScript helper dependencies.

## Security

Curvance maintains a public bug bounty for deployed smart contracts. Submit
potential vulnerabilities to security@curvance.com and allow the team time to
investigate before public disclosure.

Current scope, exclusions, payout guidance, and public audit links are maintained
at [docs.curvance.com](https://docs.curvance.com).

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
  - Confirm with `forge -V`.
- Node.js with Corepack or pnpm
  - `package.json` pins `pnpm@11.1.1`.
- Git submodules
  - External Solidity dependencies live under `lib/`.
- Optional editor tooling
  - [Solhint](https://github.com/protofire/solhint)
  - [Prettier Plugin Solidity](https://github.com/prettier-solidity/prettier-plugin-solidity)

## Setup

1. Clone the repo and initialize submodules.

```sh
git submodule update --init --recursive
```

2. Install JavaScript dependencies for helper scripts.

```sh
pnpm install
```

3. Copy `.env.sample` to `.env` and fill in the RPC URLs and private key
   values needed for fork tests or scripts.

```sh
cp .env.sample .env
```

On Windows PowerShell:

```powershell
Copy-Item .env.sample .env
```

4. Build the contracts.

```sh
forge build
```

## Repository Layout

- `contracts/`: production contracts, libraries, interfaces, mocks, and views.
- `tests/`: active Foundry test root from `foundry.toml`.
- `disabled_tests/`: deprecated-surface tests for depreciated contracts kept out of normal Foundry runs.
- `script/`: Forge scripts.
- `lib/`: git submodule dependencies.
- `artifacts/` and `cache/`: generated Foundry output.

## Code Safety

The contract set is large and individual components may have different launch,
audit, or deprecation status. Check the current deployment plan and public audit
reports before treating a contract as live scope. Deprecated contracts may still
have tests under `disabled_tests/` so repeated reports can be closed without
running those tests in the active suite.

## Common Commands

### Build

```sh
forge build
```

### Run Tests

Run the active Foundry test suite:

```sh
forge test
```

Run a specific file:

```sh
forge test --match-path tests/oracles/OracleManager/functions/GetPrice.t.sol
```

Run a specific test name:

```sh
forge test --match-test test_getPrice_success
```

Add verbosity when debugging:

```sh
forge test -vv
```

### Coverage

```sh
forge coverage
```

### Scripts

```sh
forge script script/<script-name>.s.sol
```

### Optional Fuzzing Helpers

The `Makefile` includes Echidna and Medusa helpers. They require the matching
fuzzer binaries to be installed locally.

```sh
make echidna-local
make medusa-local
```

## Solidity and Formatting

- Solidity compiler: `0.8.28`.
- EVM version: `cancun`.
- Foundry output directory: `artifacts/`.
- Active test root: `tests/`.
- Solidity line length: 79 columns.
- Solidity indentation: 4 spaces.
- Repo line endings: LF, except Windows batch files.

These values are configured in `foundry.toml`, `.editorconfig`, `.gitattributes`,
`.prettierrc.yaml`, and `.solhint.json`.

## Internal Code Guidelines

### Import Order

1. Internally developed contracts
2. Internally developed libraries
3. Externally developed libraries
4. Internally developed interfaces
5. Externally developed interfaces
6. Internally developed test contracts
7. Externally developed test contracts
8. Internally developed mocks
9. Externally developed mocks

### Contract Layout

1. Types
2. Constants
3. Storage
4. Events
5. Errors
6. Constructor
7. External functions
8. Public functions
9. Internal functions
10. Private functions

### Struct Packing

Structs used for permanent storage, such as token or oracle configuration, should
be packed tightly to reduce runtime SLOAD cost. Local memory structs should use
full-size values such as `uint256` when that avoids repeated conversion work.

### A/B State Variables

Hot paths may use `0`, `1`, and `2` state flags instead of booleans when the gas
saving is worth the extra documentation burden. Document the meaning at the
storage field or constant.

### Precomputed Selectors

Contracts near the Spurious Dragon size limit may store precomputed custom error
selectors. When a selector is used in three or more direct reverts, store it as a
documented constant and use direct revert assembly where that reduces bytecode.

### Permission Checks

Prefer internal permission-check functions over modifiers for repeated checks.
This keeps permission logic explicit while avoiding repeated modifier inlining in
large contracts.

Adding risk to the system, such as listing a new asset, requires elevated
permissions. Removing risk, such as pausing a market action, uses standard DAO
permissions unless the contract documents a stricter path.

## Code Review

Two approvals are required before a pull request can merge.

If a change should block merge, request changes instead of leaving the concern as
a non-blocking comment. For recurring Solidity style questions, this README is
the default reference when it covers the topic.

GitHub automatically assigns two developers in a round-robin pattern and accounts
for existing review load.

## Branching Strategy

The repo currently uses:

```text
feature -> develop -> main
```

Feature branches should branch from `develop`, and pull requests should target
`develop` unless a maintainer gives different release instructions. Branch names
should use a short, descriptive task name.

Admins sync `develop` into `main` for releases.

## Additional Information

*Last updated: 2026-06-19*

*Maintained by: Curvance Core Team*
