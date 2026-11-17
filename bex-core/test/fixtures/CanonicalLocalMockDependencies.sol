// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev ONLY disposable localhost Anvil fixture; not a real order book, proof,
///      oracle, token, solver registry, or an authorized payment event.
contract LocalMockSourceOrderBook {
    function exposesPlaintextValidity() external pure returns (bool) {
        return true;
    }
}

contract LocalMockFinalityOracle {
    function matches(uint256, bytes32) external pure returns (bool) {
        return false;
    }
}

contract LocalMockMatcher { }
