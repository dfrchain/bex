# BEX — Cross-Chain Execution Layer

BEX is the cross-chain execution layer of DFRChain. It takes signed cross-chain
orders, has them executed by registered solvers, and settles them against
verifiable receipts. BEX is currently deployed on the Base Sepolia and
Arbitrum Sepolia testnets.

## Repository structure

```text
.
├── LICENSE                     Apache License 2.0 (see file-level SPDX notices)
├── README.md
├── OPEN_SOURCE_BOUNDARY.md      Published-vs-proprietary scope and release checklist
├── SECURITY.md                  Private vulnerability reporting
├── docs/
│   └── onboarding.md           Contributor onboarding guide
├── .gitignore
├── .gitmodules                 forge-std, halmos-cheatcodes (public libraries)
└── bex-core/
    ├── foundry.toml
    ├── src/
    │   ├── OrderBook.sol               Receives signed orders, locks funds, archives batches
    │   ├── Settlement.sol              Verifies receipts and match-verifier results; settles or refunds
    │   ├── SolverRegistry.sol          Solver registration, bonds, exposure
    │   ├── AttestationVerifier.sol     Receipt verification
    │   ├── CanonicalReceiptRegistry.sol Registry of canonical receipts
    │   ├── FeeRouter.sol               Fee routing
    │   ├── PaymentReceiptSink.sol      Accepts payments and emits receipts
    │   ├── interfaces/                 Contract interfaces (10 files)
    │   ├── types/BexTypes.sol          Order / Fill / BatchSettlement / OrderState
    │   └── mocks/MockERC20.sol         Mock ERC20 asset for local development only
    ├── script/
    │   └── DeployReceiptLocal.s.sol    Local Anvil deployment: mock asset + PaymentReceiptSink
    └── test/
        ├── FeeRouter.t.sol
        ├── fixtures/                   Local-only mock fixtures (Anvil chain id 1)
        ├── mocks/Mock4788.sol          Mock EIP-4788 beacon root provider
        └── guards/                     Receipt registry and payment sink guards
```

## Scope note

This repository is a **partial source excerpt**, not a verified standalone
build. Some imports (including shared helper libraries under
`bex-core/src/libraries/`) are absent. Therefore `forge build` and `forge test`
are **expected to be blocked by missing dependencies** until the public
release is completed. Commands below are illustrative and were not executed
for this snapshot. See [OPEN_SOURCE_BOUNDARY.md](OPEN_SOURCE_BOUNDARY.md).

## Reproducible public receipt-sink slice

The public `PaymentReceiptSink.sol` now has a minimal isolated Foundry build/test
that does **not** require the unpublished helpers used by other contracts:

```bash
bash bex-core/examples/receipt-sink/run.sh
```

The script stages only the public receipt sink, its ERC-20 interface, test
token, and two minimal public helper libraries into a separate temporary
Foundry project. It tests exact payment receipts, duplicate prevention, and
the asset allowlist. The isolated smoke gate is also configured in
[GitHub Actions](.github/workflows/receipt-sink-smoke.yml).

**Important:** `forge build` or `forge test` at the `bex-core/` root
still requires the intentionally omitted dependencies of other protocol
contracts. The minimal helper `SafeTransfer.sol` is only sufficient for
the isolated receipt-sink target and is not the full private library.

See [PUBLIC_RELEASE_REVIEW.md](PUBLIC_RELEASE_REVIEW.md) for the private/public
baseline comparison and further-publication restrictions.

## Quick start

```bash
# Clone this repository (not verified: command not actually run to verify)
git clone https://github.com/dfrchain/bex.git
cd bex/bex-core

# Not verified: fetch the submodule dependencies (forge-std, halmos-cheatcodes)
git submodule update --init --recursive

# Not verified
forge build

# Not verified
forge test
```

Prerequisites: git and Foundry (the source docs specify forge 1.8.3). See
`docs/onboarding.md` for the full guide.

## Local demo (Anvil)

```bash
# Not verified: start a local chain (default 127.0.0.1:8545)
anvil

# Not verified: deploy the mock asset and PaymentReceiptSink, then make a real pay() call
forge script script/DeployReceiptLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --unlocked --broadcast
```

## Testing

```bash
# Not verified: full test set (from the source repository's own docs)
forge test

# Not verified: guard set only
forge test --match-path 'test/guards/*' -vv
```

## Links

- Website: <https://dfrchain.com>
- Research notes: <https://news.dfrchain.com>
- Engineering journal: <https://blog.dfrchain.com>
- GitHub: <https://github.com/dfrchain>

## License

The root repository includes the Apache License 2.0 ([LICENSE](LICENSE)).
Some Solidity source files carry their own `SPDX-License-Identifier: MIT`
headers; check each file's license and third-party notices when reusing code.
See [OPEN_SOURCE_BOUNDARY.md](OPEN_SOURCE_BOUNDARY.md) for scope and
[SECURITY.md](SECURITY.md) for confidential reports.
