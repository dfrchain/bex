# BEX — Cross-Chain Execution Layer

BEX is the cross-chain execution layer of DFRChain. It takes signed cross-chain
orders, has them executed by registered solvers, and settles them against
verifiable receipts. BEX is currently deployed on the Base Sepolia and
Arbitrum Sepolia testnets.

## Repository structure

```text
.
├── LICENSE                     Apache License 2.0
├── README.md
├── docs/
│   └── onboarding.md           Contributor onboarding guide
├── .gitignore
├── .gitmodules                 forge-std, halmos-cheatcodes (public libraries)
└── bex-core/
    ├── foundry.toml
    ├── src/
    │   ├── OrderBook.sol               Receives signed orders, locks funds, archives batches
    │   ├── Settlement.sol              Verifies receipts, recomputes settlement, releases funds, refunds on timeout
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

This repository is a source excerpt: it publishes a subset of the BEX
contracts, interfaces, and tests. The included contracts import shared helper
libraries that are intentionally not part of this excerpt, so this snapshot on
its own is not a standalone buildable package as-is. All commands below are
taken from the source repository's own documentation. None of them were
executed against this snapshot during preparation, and each is marked
(not verified).

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

Apache License 2.0. See [LICENSE](LICENSE).
