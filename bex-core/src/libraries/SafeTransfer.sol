// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @notice Minimal ERC-20 transfer helper required by the public receipt-sink example.
/// @dev Checks contract code and accepts standard ERC-20 boolean or no-return semantics.
///      This intentionally exposes no additional private BEX transfer helpers.
library SafeTransfer {
    error TransferFailed();

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (address(token).code.length == 0) revert TransferFailed();
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
