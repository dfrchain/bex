// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CanonicalReceiptRegistry } from "../../src/CanonicalReceiptRegistry.sol";

contract LegacyCanonicalOrderRebindingTest is Test {
    CanonicalReceiptRegistry internal registry;

    function setUp() public {
        registry = new CanonicalReceiptRegistry(address(this));
    }

    function _register(bytes32 digest, uint256 orderId) internal {
        // Use short ABI slices to avoid the viaIR compiler's optimizer stack
        // issue when a test contract directly passes nine calldata arguments.
        bytes memory head = abi.encode(digest, uint256(4), orderId);
        bytes memory tail =
            abi.encode(uint256(1), address(0xA001), address(0xB002), address(0xC003), uint256(123), address(0xD004));
        (bool success, bytes memory response) =
            address(registry).call(bytes.concat(CanonicalReceiptRegistry.setContext.selector, head, tail));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(response, 0x20), mload(response))
            }
        }
    }

    function test_BEX02_LegacyCannotBindSameOrderToDistinctDigests() public {
        bytes32 first = keccak256("first");
        bytes32 second = keccak256("second");
        _register(first, 7);
        vm.expectRevert(CanonicalReceiptRegistry.OrderAlreadyBound.selector);
        _register(second, 7);
        assertEq(registry.registeredDigestByOrder(7), first);
        _register(second, 8);
    }

    function test_BEX02_LegacyRejectsZeroDigestEvenForAuthorizedRegistrar() public {
        vm.expectRevert(CanonicalReceiptRegistry.InvalidContext.selector);
        _register(bytes32(0), 7);
    }

    function test_BEX02_LegacyCannotRebindSameDigestToAnotherOrder() public {
        bytes32 digest = keccak256("one");
        _register(digest, 7);
        vm.expectRevert(CanonicalReceiptRegistry.AlreadySet.selector);
        _register(digest, 8);
    }
}
