// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice 第一版只用到最小 ERC20 子集。
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
