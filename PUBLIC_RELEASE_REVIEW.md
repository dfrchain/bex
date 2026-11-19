# Private-to-public release boundary — review snapshot

Snapshot date: 2026-11-19. **This is a comparison of selected local Git commits, not a live mirror or history-wide leak audit.**

## BEX tree comparison
- Private source: `sudorm-rf0/dfrchain` local `GitHub/dfrchain-cleanup` commit `e058228` (main).
- Public baseline: `dfrchain/bex` commit `d4da1be` (before receipt-sink additions).
- Compared the `bex-core/` path only: **723 private files**, **28 public files**, **28 overlapping paths**, **695 private-only paths**.
- Of 28 overlapping paths, **5 exact Git blob matches and 23 content differences**. Differences must be reviewed; same path does not imply same version or identical logic.
- No original private-only files were copied as a batch. The minimal public receipt-sink helpers were specifically authored/reviewed, and reference the existing public `PaymentReceiptSink.sol` source.

## Release boundaries
- Public allowlist for this isolated deliverable: `bex-core/src/PaymentReceiptSink.sol`, `bex-core/src/interfaces/IERC20.sol`, `bex-core/src/mocks/MockERC20.sol`, `bex-core/src/libraries/SafeTransfer.sol`, `bex-core/src/libraries/ReceiptChainDomain.sol`, `bex-core/examples/receipt-sink/**`.
- **Not approved for bulk publication:** other `bex-core/src/libraries/**`, private contract tests, production deploy scripts/configuration, off-chain Solvers, pricing/routing/market data, customer artifacts or key material.
- Public receipt-sink CI is an **isolated subset**. The rest of this repository still contains omitted dependencies and is not promised to build independently.
- The public helper `SafeTransfer.sol` deliberately exports only the method needed for the public receipt sink. It is **not** a drop-in replacement for the complete private SafeTransfer library used by other contracts.

## Mandatory pre-release checks
1. Compare an exact immutable private source commit against an exact public target commit. Review both additions and modifications and record the diff inventory.
2. Check ownership, individual SPDX headers, third-party licenses and existing Apache-2.0 grants.
3. Scan worktrees and **all public history** for credentials, then rotate compromised values. No history-wide credential scan is certified by this report.
4. Run the isolated Foundry smoke gate from a clean public checkout and record test output. Do not claim the **entire** protocol compiles from this excerpt.
5. Obtain maintainer review before any future private-to-public synchronization.

This file does not grant authority to disclose additional private source.
