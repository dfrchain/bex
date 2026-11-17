// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ICanonicalReceiptSource } from "./interfaces/ICanonicalReceiptSource.sol";
import { ReceiptChainDomain } from "./libraries/ReceiptChainDomain.sol";

/// @title Canonical 回执定义注册表（源链）
/// @notice 第三轮外部评审 Critical 修复（RECEIPT-CANONICALIZATION-001）：
///         **源链独立重算 receiptHash，不接受证明者提交的值。**
///
///         设计要点：
///         * 回执上下文（epoch / orderId / 目标链 / sink / 资产 / 金额 / 收款人 / solver）
///           在批次阶段由源链写入，来源是**已锁定的订单与市场配置**，不是证明者 calldata；
///         * 写入后 **immutable**（`AlreadySet` 拒绝重复登记），证明者无法事后替换；
///         * `receiptHashOf` 的编码与目标链 `PaymentReceiptSink.receiptHashOf` 逐字段一致。
///
/// @dev 为什么 asset 必须来自这里而不是 proof：balance delta 判断不了代币的经济价值。
///      攻击者可部署 FakeUSDC（balanceOf 随便返回、transferFrom 随便成功），
///      sink 会"认为已入账"。因此 asset 必须是协议认可的市场 canonical 资产。
/// @dev 边界：本合约只**定义**回执，不验证目标链状态，也不释放资金。
contract CanonicalReceiptRegistry is ICanonicalReceiptSource {
    struct ReceiptContext {
        uint64 epoch;
        uint256 orderId;
        uint64 sourceChainId;
        uint64 targetChainId;
        address solver;
        address recipient;
        address asset;
        uint256 amount;
        address receiptSink;
        bool set;
    }

    /// @notice 可登记回执上下文的权威角色（部署时的 Settlement 或运营多签）。
    address public immutable registrar;

    error NotRegistrar();
    error AlreadySet();
    error NotSet();
    error InvalidContext();
    error OrderAlreadyBound();

    /// @notice Reject a second digest attempting to reuse the same order.
    mapping(uint256 => bytes32) public registeredDigestByOrder;

    /// @notice digest → 已锁定的回执上下文。
    mapping(bytes32 => ReceiptContext) public contexts;

    event ReceiptContextSet(
        bytes32 indexed digest,
        uint64 indexed epoch,
        uint256 orderId,
        address receiptSink,
        address asset,
        uint256 amount,
        address recipient,
        bytes32 receiptHash
    );

    constructor(address registrar_) {
        // The registrar defines payment business context. An EOA makes this an
        // unreviewable single-key authority, so production wiring must use a
        // contract boundary (Settlement, timelock, or audited multisig).
        if (registrar_ == address(0) || registrar_.code.length == 0) revert InvalidContext();
        registrar = registrar_;
    }

    /// @notice 登记某结算摘要对应的 canonical 回执上下文。**只能登记一次**。
    /// @dev 参数必须来自源链已锁定状态（订单簿订单 + 市场配置），不得来自证明者。
    function setContext(
        bytes32 digest,
        uint64 epoch,
        uint256 orderId,
        uint64 targetChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount,
        address receiptSink
    ) external {
        if (msg.sender != registrar) revert NotRegistrar();
        // The receipt hash encodes sourceChainId as uint64; a larger EVM
        // chainid must never silently alias a lower-64-bit chain identity.
        uint64 sourceChain = ReceiptChainDomain.checked(block.chainid);
        ReceiptContext memory next = ReceiptContext({
            epoch: epoch,
            orderId: orderId,
            sourceChainId: sourceChain,
            targetChainId: targetChainId,
            solver: solver,
            recipient: recipient,
            asset: asset,
            amount: amount,
            receiptSink: receiptSink,
            set: true
        });
        _commitContext(digest, next);
    }

    /// @dev Localized validation and write reduce optimizer stack liveness
    ///      without changing the external registrar ABI.
    function _commitContext(bytes32 digest, ReceiptContext memory next) private {
        if (contexts[digest].set) revert AlreadySet();
        if (digest == bytes32(0)) revert InvalidContext();
        if (registeredDigestByOrder[next.orderId] != bytes32(0)) revert OrderAlreadyBound();
        if (
            next.receiptSink == address(0) || next.asset == address(0) || next.recipient == address(0)
                || next.amount == 0 || next.targetChainId == 0 || next.solver == address(0)
        ) revert InvalidContext();
        registeredDigestByOrder[next.orderId] = digest;
        contexts[digest] = next;
        emit ReceiptContextSet(
            digest, next.epoch, next.orderId, next.receiptSink, next.asset, next.amount, next.recipient, _hash(next)
        );
    }

    /// @notice 该摘要的 canonical 回执哈希（源链独立重算）。
    function receiptHashOf(bytes32 digest) public view returns (bytes32) {
        ReceiptContext memory c = contexts[digest];
        if (!c.set) revert NotSet();
        return _hash(c);
    }

    /// @inheritdoc ICanonicalReceiptSource
    function canonicalReceipt(bytes32 digest)
        external
        view
        override
        returns (
            uint64 targetChainId,
            address receiptSink,
            address asset,
            uint256 amount,
            address recipient,
            bytes32 receiptHash
        )
    {
        ReceiptContext memory c = contexts[digest];
        if (!c.set) revert NotSet();
        return (c.targetChainId, c.receiptSink, c.asset, c.amount, c.recipient, _hash(c));
    }

    /// @dev 编码必须与目标链 `PaymentReceiptSink.receiptHashOf` **完全一致**。
    function _hash(ReceiptContext memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "BEX_PAYMENT_RECEIPT_V1",
                c.epoch,
                c.orderId,
                c.sourceChainId,
                c.targetChainId,
                c.solver,
                c.recipient,
                c.asset,
                c.amount
            )
        );
    }
}
