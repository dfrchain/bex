// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract Mock4788 {
    mapping(uint256 => bytes32) public roots;

    function set(uint256 ts, bytes32 r) external {
        roots[ts] = r;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length == 32, "bad len");
        uint256 ts = abi.decode(input, (uint256));
        bytes32 r = roots[ts];
        require(r != bytes32(0), "no root");
        return abi.encode(r);
    }
}
