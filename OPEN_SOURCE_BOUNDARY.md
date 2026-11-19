# Public source boundary and release policy

This repository is a **public source excerpt** of BEX, not the complete commercial execution system and not a currently verified standalone Foundry distribution.

## Existing open-source grant
The repository includes Apache-2.0 licensing at the root. Individual Solidity files may contain `SPDX-License-Identifier: MIT`. A file-level SPDX identifier is material: do not silently change the license of that file or claim every file is covered solely by Apache-2.0. Review per-file headers, authorship, third-party dependencies and the applicable notice obligations before redistribution. Previously received open-source license grants cannot be retroactively revoked by deleting public source.

## Published code
- Included: portions of `bex-core/src/` such as order book, settlement, attestation verification, solver registry, fee and receipt modules; interfaces, selected mocks, scripts and tests.
- The included contracts disclose relevant on-chain trust assumptions, limits, signing, order and settlement semantics. These are **already public**, not confidential by virtue of a new policy.
- **Known limitation:** certain contracts import shared helper libraries under `bex-core/src/libraries/` that are absent from this excerpt. As distributed, a standalone `forge build` / `forge test` is not promised to succeed. Do not advertise the excerpt as a reproducible full release until the required audited/public dependencies and checks are supplied.

## Remain private unless separately approved
Off-chain solver routing and execution strategies, market-making or fee optimization, proprietary matching services, pricing logic, private infrastructure configuration, account credentials, customers' data, internal operational playbooks and unpublished research belong in private repositories. These categories do not imply that previously published code may be reclassified or its license revoked.

## Smart contract transparency
If a contract is deployed and presented as verifiable, publish/verifiably match the deployed source and dependencies needed for independent assessment. Public source does not replace review, testing or an audit; do not make production-safety claims based on this excerpt.

## Public-release checklist
1. Compare the **exact public diff** to the intended approved subset. Never bulk-sync the complete private `bex-core` or worktree.
2. Validate rights to all copied files and submodules, and check SPDX/NOTICE obligations.
3. Run a history-aware secrets scan on all public refs, not just the working tree. Treat any discovered live secret as compromised; revoke and rotate it.
4. Inspect docs, fixtures, scripts, constants, commit messages and deployments for secret material, non-public signer metadata or commercial configurations.
5. Execute `forge build` and relevant tests in a clean clone when claiming buildability, recording the exact commit and result.
6. Require maintainer review before merging public release changes.

## Grant scope
Grant proposals must define the specific deliverables to publish, license, milestones and ownership. No grant application may promise release of separate proprietary solver services without an explicit decision and agreement.

## Reporting
Report suspected exposed secrets or sensitive security defects privately to **hello@dfrchain.com**; do not publish the exploit, production credentials or customer information in issues.
