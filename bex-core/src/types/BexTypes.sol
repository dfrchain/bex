// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title BEX 第一层共用类型
/// @notice 字段顺序严格对应 `06-数据编码与哈希规范.md` 与 `04-接口与状态机规范.md`，
///         任何调整都会改变 orderHash 与 settlementDigest，必须同步升版本号。

/// @notice 用户订单。字段顺序即 orderHash 的 ABI 编码顺序，不得调整。
struct Order {
    address trader;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint64 epoch;
    uint64 validUntil;
    bool partiallyFillable;
    uint256 nonce;
}

/// @notice 密封档订单（承诺制）：链上**只存承诺与金额上界**，订单内容（价格、数量、方向）
///         留在用户本地加密的信封里，封盘后由门限委员会解密并签发揭示证书。
/// @dev 与 `Order` 的差别即密封档的泄漏面（见 `docs/23` §3.3）：
///      - 链上可见：trader、sellToken、buyToken、maxSellAmount（上界）、commitment、ciphertextHash、epoch；
///      - 链上不可见：限价、真实数量（只能推出 ≤ maxSellAmount）、方向以外的意图、盐。
/// @dev **存储打包（2026-09-26 优化）**：字段顺序按"能合槽就合槽"排列——
///      `trader(20) + epoch(8)` 同槽、`maxSellAmount` 用 uint120（与 `MAX_ORDER_VALUE` 同界），
///      整个结构占 **7 个槽**。满批 200 单结算要逐单读一次，省下的 1 个冷 SLOAD/单 ≈ 42 万 gas（实测见 `test/GasReportSealed.t.sol`）。
///      改字段顺序或类型会改变 orderId（因为 orderId 对公开字段做 ABI 编码），必须同步升版本。
struct SealedOrder {
    address trader;
    /// @dev 与 trader 同槽（20+8=28 字节）。
    uint64 epoch;
    address sellToken;
    address buyToken;
    /// @dev 金额上界，同时也是锁定额；上限为 `MAX_ORDER_VALUE = type(uint120).max`。
    ///      结算时按已揭示的真实成交量释放，余数退回用户。
    uint120 maxSellAmount;
    /// @dev 订单内容承诺：`keccak(内容 ‖ 盐)`，盐只存在于用户与委员会之间。
    bytes32 commitment;
    /// @dev 加密信封的哈希（数据可用性指针），委员会用它取回密文。
    bytes32 ciphertextHash;
    uint256 nonce;
}

/// @notice 密封档**揭示**（开盒）后的订单内容：封盘后与揭示证书一起提交上链。
/// @dev 承诺式订单簿的链上强制点：`commitment` 必须等于本结构（含盐）按
///      `SealedOrderLib.commitmentOf` 重算的结果，因此委员会无法用另一份内容替换用户的承诺。
///      字段顺序冻结在 `docs/05` §40，任何调整都会改变承诺值，必须升版本号。
struct SealedOpening {
    bytes32 orderId;
    address trader;
    address sellToken;
    address buyToken;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint64 validUntil;
    bool partiallyFillable;
    uint256 nonce;
    bytes32 salt;
}

/// @notice 单笔成交明细。
struct Fill {
    bytes32 orderId;
    uint256 amountSold;
    uint256 amountReceived;
}

/// @notice 结算载荷。
/// @dev 已按 `docs/05-M2接口钉死记录.md` 第五节冻结：
///      - `orderIds` 必须是本批**全部封盘订单**（含未成交订单），按 `(limit, orderId)` 升序；
///      - `submissionIndices[i]` 是 `orderIds[i]` 在 `OrderBook` 提交顺序中的序号；
///      - 合约据此校验 `epochOrderIdAt(epoch, idx) == orderIds[i]`，并用 256 位位图
///        证明载荷恰好覆盖 `0..N-1`，从而在不排序、不信任撮合方的前提下完成集合完整性校验。
struct BatchSettlement {
    uint64 epoch;
    uint256 chainId;
    bytes32 pairHash;
    /// @dev 交易对定义。链上复算必须知道 base/quote 才能判定订单方向：
    ///      sellToken == baseToken 为卖单（ask），否则为买单（bid）。
    ///      `pairHash` 必须等于 `keccak256(abi.encode(baseToken, quoteToken))`（见 docs/05 第七节）。
    address baseToken;
    address quoteToken;
    uint256 priceNum;
    uint256 priceDen;
    /// @dev 最终成交量（base 单位）。取整可行性回退可能把它压到 `_scan` 复算出的最大值以下，
    ///      因此必须由载荷显式声明并纳入摘要：链上校验 `volume ≤ _scan 复算值` 与分配不变量，
    ///      "它是否为最大可行值"由 3-of-5 验证者在链下核验（见 docs/05 第十一节，Option B）。
    uint256 volume;
    bytes32 orderSetHash;
    bytes32 matcherVersion;
    uint64 deadline;
    address solver;
    bytes32[] orderIds;
    uint32[] submissionIndices;
    Fill[] fills;
}

/// @notice 订单状态机。取值顺序必须与 `04-接口与状态机规范.md` §三 的转移表一致。
enum OrderState {
    NONE,
    SUBMITTED,
    LOCKED,
    AUCTIONED,
    AWARDED,
    FILLED,
    ATTESTED,
    SETTLED,
    REFUNDED,
    CANCELLED
}
