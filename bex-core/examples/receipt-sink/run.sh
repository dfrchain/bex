#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${TMPDIR:-/tmp}/bex-public-receipt-${USER:-runner}-$$"
mkdir -p "$STAGE/src/interfaces" "$STAGE/src/libraries" "$STAGE/src/mocks" "$STAGE/test"
for file in src/PaymentReceiptSink.sol src/interfaces/IERC20.sol src/libraries/SafeTransfer.sol src/libraries/ReceiptChainDomain.sol src/mocks/MockERC20.sol; do
  cp "$ROOT/$file" "$STAGE/$file"
done
cp "$ROOT/examples/receipt-sink/foundry.toml" "$STAGE/foundry.toml"
cp "$ROOT/examples/receipt-sink/test/ReceiptSinkMinimal.t.sol" "$STAGE/test/ReceiptSinkMinimal.t.sol"
(cd "$STAGE" && forge build && forge test -vv)
echo "Staged test project: $STAGE"
