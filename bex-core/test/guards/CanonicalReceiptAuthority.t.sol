// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CanonicalReceiptRegistry } from "../../src/CanonicalReceiptRegistry.sol";

/// @dev A contract registrar, as required by CanonicalReceiptRegistry constructor.
/// It deliberately has no access to OrderBook, Settlement, or authenticated fills.
contract ArbitraryCanonicalRegistrar {
    function register(CanonicalReceiptRegistry registry, bytes32 digest, uint256 amount) external {
        registry.setContext(
            digest,
            7, // epoch
            42, // orderId
            11155111, // target chain
            address(0x5101), // solver
            address(0x5102), // recipient
            address(0x5103), // canonical-looking asset
            amount,
            address(0x5104) // receipt sink
        );
    }
}

/// @notice BEX-02 threat-model witness, NOT a proof of a complete settlement drain.
/// Extracted from #43 commit 0615eba: only the witness below is carried over.
/// The source commit's two guard tests (context cannot be overwritten;
/// non-registrar cannot register) are already covered at the tip by
/// test/poc/G2ReceiptProof.t.sol and are deliberately not duplicated.
contract CanonicalReceiptAuthorityTest is Test {
    ArbitraryCanonicalRegistrar internal authority;
    CanonicalReceiptRegistry internal registry;

    function setUp() public {
        authority = new ArbitraryCanonicalRegistrar();
        registry = new CanonicalReceiptRegistry(address(authority));
    }

    function test_ThreatModel_ContractRegistrarCanChooseUnderpaymentWithoutOrderProof() public {
        bytes32 digest = keccak256("claimed-locked-order-with-100-units-due");

        // The registry has no order/fill/escrow dependency; a contract registrar
        // can register one unit even if the off-chain assertion says 100 are due.
        authority.register(registry, digest, 1);
        (
            uint64 targetChainId,
            address receiptSink,
            address asset,
            uint256 amount,
            address recipient,
            bytes32 receiptHash
        ) = registry.canonicalReceipt(digest);

        assertEq(targetChainId, 11155111);
        assertEq(receiptSink, address(0x5104));
        assertEq(asset, address(0x5103));
        assertEq(amount, 1, "registrar chooses the obligation amount");
        assertEq(recipient, address(0x5102));
        assertEq(receiptHash, registry.receiptHashOf(digest));
        assertTrue(receiptHash != bytes32(0));

        // This witness DOES NOT establish a complete exploit: end-to-end
        // settlement release, target-chain proofs and deployment permissions
        // must be evaluated separately.
    }
}
