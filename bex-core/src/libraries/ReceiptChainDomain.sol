// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Guard a receipt's uint64 chain-domain encoding against truncation.
library ReceiptChainDomain {
    error UnsupportedChainId();

    function checked(uint256 chainId) internal pure returns (uint64) {
        if (chainId > type(uint64).max) revert UnsupportedChainId();
        return uint64(chainId);
    }
}
