// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Canonical 付款回执定义源
/// @notice 第三轮外部评审的 Critical 修复（RECEIPT-CANONICALIZATION-001）：
///         **源链必须自己重算 receiptHash，不能相信证明者提交的值。**
///
///         否则攻击者可以自造一个对自己有利的回执（例如 asset=FakeToken、amount=1），
///         在目标链上得到 `paid[fakeHash] = 1`，再把它和真实订单的 digest 拼起来。
///         此时"receiptHash 绑定了很多字段"毫无安全意义——绑定的只是攻击者自选的字段。
///
/// @dev 权威源必须只用**源链已锁定的状态**（订单簿里的订单、批次配置、市场登记表）
///      来推导，不得接受任何来自证明者的输入。
interface ICanonicalReceiptSource {
    /// @notice 针对某个结算摘要，返回源链认可的 canonical 回执定义。
    /// @param digest 结算摘要（已绑定 epoch / 批次 / solver 等源链状态）
    /// @return targetChainId 目标链 ID（来自市场/订单配置，不是 proof）
    /// @return receiptSink 目标链上协议认可的回执合约（配置项，不是 proof）
    /// @return asset 目标链结算资产（必须是市场 canonical 资产，不是 proof 自报）
    /// @return amount 应付金额（来自订单/批次计算，不是 proof 自报）
    /// @return recipient 收款人（来自订单，不是 proof 自报）
    /// @return receiptHash 源链独立算出的 canonical 回执哈希
    function canonicalReceipt(bytes32 digest)
        external
        view
        returns (
            uint64 targetChainId,
            address receiptSink,
            address asset,
            uint256 amount,
            address recipient,
            bytes32 receiptHash
        );
}
