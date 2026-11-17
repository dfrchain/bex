// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { SafeTransfer } from "./libraries/SafeTransfer.sol";
import { ReceiptChainDomain } from "./libraries/ReceiptChainDomain.sol";

/// @title 目标链付款回执接收器
/// @notice 修复一个**真实的资金语义缺陷**（外部评审 2026-10-06 第二轮，Critical 级）：
///         原实现用"收款人余额 ≥ 应付金额"作为源链释放资金的凭据。
///         但余额证明不了付款——用户的余额可能来自他原本就有的钱、第三方转账、
///         其他协议收入，或多笔转账的合计。**"这个地址挺有钱" ≠ "solver 为这个订单付了款"**。
///
///         本合约建立**协议专属、唯一、可证明**的付款回执：
///         求解者通过本合约付款（而不是直接 ERC-20 转账），合约在付款成功后写入
///         `paid[receiptHash] = 1`；源链证明这个存储槽，而不是证明余额。
///
/// @dev 回执绑定完整业务上下文（orderId / epoch / 源链 / 目标链 / solver / recipient /
///      asset / amount），任何一项不同都会得到不同的 receiptHash，
///      因此不存在"A 单的付款冒充 B 单"的空间。
/// @dev 幂等：同一 receiptHash 只能结算一次（重复付款 revert），避免重试造成重复记账。
contract PaymentReceiptSink {
    using SafeTransfer for IERC20;

    /// @dev 重入锁：`pay` 会在转账后回读收款人余额校验到账额，而转账对外部代币
    ///      发起外部调用。锁住整个函数，避免恶意/回调型代币在 `safeTransferFrom`
    ///      期间重入 `pay` 打乱 before/after 差额判断。
    uint256 private _reentrancyLock = 1;

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Reentrant();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    /// @notice 协议认可的目标链结算资产（第三轮评审第 5 条：资产必须 canonical）。
    /// @dev 为什么必须有它：`before/after` 差额判断不了代币的经济价值。
    ///      攻击者可部署 FakeUSDC（`balanceOf` 随便返回、`transferFrom` 随便成功），
    ///      sink 会"认为已入账"。因此 `pay()` 只接受**白名单内**的资产。
    ///      设计上是不可变的集合（部署时定），没有增加白名单的接口——
    ///      减少管理员权限面；需要扩展时重新部署 sink 并更新源链 canonical 配置。
    mapping(address => bool) public allowedAsset;

    /// @notice 已完成的付款回执：receiptHash → 1 表示已付款。
    /// @dev 源链的存储证明会直接查这个槽，因此**槽的布局是跨链接口的一部分**，
    ///      不能随意改动（改了要同步改验证器的 slot 推导）。
    mapping(bytes32 => uint256) public paid;

    error AlreadyPaid(bytes32 receiptHash);
    error ZeroAmount();
    error ZeroRecipient();
    error AmountMismatch();
    error Reentrant();
    error AssetNotAllowed(address asset);

    /// @param allowedAssets_ 部署时固定的 canonical 资产白名单（不可为空、不可为零地址）
    constructor(address[] memory allowedAssets_) {
        if (allowedAssets_.length == 0) revert AssetNotAllowed(address(0));
        for (uint256 i = 0; i < allowedAssets_.length; i++) {
            address a = allowedAssets_[i];
            // Fail closed at deployment: a mistaken EOA/undeployed token can never
            // satisfy a canonical ERC-20 payment receipt on this immutable sink.
            if (a.code.length == 0) revert AssetNotAllowed(a);
            allowedAsset[a] = true;
        }
    }

    event PaymentReceipted(
        bytes32 indexed receiptHash,
        uint256 indexed epoch,
        uint256 indexed orderId,
        uint64 sourceChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount
    );

    /// @notice 计算回执哈希。链下与链上必须用**完全相同的编码**。
    function receiptHashOf(
        uint256 epoch,
        uint256 orderId,
        uint64 sourceChainId,
        uint64 targetChainId,
        address solver,
        address recipient,
        address asset,
        uint256 amount
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "BEX_PAYMENT_RECEIPT_V1", epoch, orderId, sourceChainId, targetChainId, solver, recipient, asset, amount
            )
        );
    }

    /// @notice 求解者通过本合约向收款人付款，并写入回执。
    /// @dev 金额以**实际转账到账额**为准：先记录 before/after，确认差额等于 amount，
    ///      挡住"返回 true 但不转账"的畸形代币（与 OrderBook 的入账校验同一纪律）。
    function pay(uint256 epoch, uint256 orderId, uint64 sourceChainId, address recipient, address asset, uint256 amount)
        external
        nonReentrant
        returns (bytes32 receiptHash)
    {
        // Encoding targetChainId as uint64 without this guard could permit
        // cross-chain receipt-domain collisions for oversized EVM chain IDs.
        // Reject before state mutation or external asset transfers.
        uint64 targetChainId = ReceiptChainDomain.checked(block.chainid);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        if (!allowedAsset[asset]) revert AssetNotAllowed(asset);

        receiptHash = receiptHashOf(epoch, orderId, sourceChainId, targetChainId, msg.sender, recipient, asset, amount);
        if (paid[receiptHash] != 0) revert AlreadyPaid(receiptHash);

        // 先写回执状态（CEI），再转账；转账失败则整笔回滚
        paid[receiptHash] = 1;

        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(recipient);
        token.safeTransferFrom(msg.sender, recipient, amount);
        if (token.balanceOf(recipient) - before != amount) revert AmountMismatch();

        emit PaymentReceipted(receiptHash, epoch, orderId, sourceChainId, msg.sender, recipient, asset, amount);
    }

    /// @notice 只读查询某回执是否已付款。
    function isPaid(bytes32 receiptHash) external view returns (bool) {
        return paid[receiptHash] != 0;
    }
}
