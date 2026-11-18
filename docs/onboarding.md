# Onboarding

> This guide explains how to get the BEX code, build and test it locally, and run a minimal integration example. All commands are taken from the source repository's docs; none were actually run against this snapshot (marked "not verified by running it here").

## Prerequisites

- git
- Foundry (`forge`, `anvil`). The source repository's docs specify forge 1.8.3.
- A local shell. No remote services or credentials are needed for the local flow below.

All commands in this guide are taken from the source repository's own
documentation. None of them were executed against this snapshot during
preparation; each is marked "not verified by running it here".

## Clone, build, test

```bash
# Clone this repository (not verified by running it here: command not actually run to verify)
git clone https://github.com/dfrchain/bex.git
cd bex/bex-core

# Not verified by running it here: fetch the submodule dependencies (forge-std, halmos-cheatcodes)
git submodule update --init --recursive

# Not verified by running it here
forge build

# Not verified by running it here: full test set
forge test

# Not verified by running it here: guard set only
forge test --match-path 'test/guards/*' -vv

# Not verified by running it here: format check
forge fmt --check
```

Scope note: this repository is a source excerpt. The included contracts import
shared helper libraries that are intentionally not part of this excerpt, so
this snapshot on its own is not a standalone buildable package as-is. If a
build fails on a missing helper library, that is expected for this excerpt.

## Minimal integration example

The smallest end-to-end local flow is the receipt sink demo. It deploys a mock
ERC20 asset and a `PaymentReceiptSink` on a local Anvil chain, then makes a
real `pay()` call and prints the receipt hash. In outline, the script deploys
a mock ERC20 asset, deploys a `PaymentReceiptSink` that allows that asset,
mints a balance to the solver, approves the sink, and calls `pay()` — see
`bex-core/script/DeployReceiptLocal.s.sol` for the exact code.

Run it (not verified by running it here):

```bash
# Not verified by running it here: start a local chain (default 127.0.0.1:8545)
anvil

# Not verified by running it here: from bex-core/
forge script script/DeployReceiptLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --unlocked --broadcast
```

To read the core flow, start with these files:

- `bex-core/src/OrderBook.sol` and `bex-core/src/interfaces/IOrderBook.sol`
  — how orders are received and locked.
- `bex-core/src/SolverRegistry.sol` — how solvers register and bond.
- `bex-core/src/Settlement.sol` — how receipts are verified and funds released.
- `bex-core/src/types/BexTypes.sol` — `Order`, `Fill`, `BatchSettlement`,
  `OrderState`.
- `bex-core/src/PaymentReceiptSink.sol` — how payments and receipts work.

## FAQ

**Which networks is BEX on?**
BEX is currently deployed on the Base Sepolia and Arbitrum Sepolia testnets.

**Can I run it locally?**
Yes. Start Anvil and run `script/DeployReceiptLocal.s.sol` as shown above
(not verified by running it here). It needs no remote services and no credentials.

**Does this repository contain all of the BEX code?**
No. This repository publishes a subset of the contracts, interfaces, and
tests. Other parts are not included in this excerpt.

**How do I run the tests?**
From `bex-core/`, run `forge test` (not verified by running it here). The guard set alone is
`forge test --match-path 'test/guards/*' -vv` (not verified by running it here).

**How do I report a problem?**
Open an issue at <https://github.com/dfrchain>.

**What license is the code under?**
Apache License 2.0. See [LICENSE](../LICENSE).
