// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Order } from "../types/BexTypes.sol";

/// @title 结算层需要的订单簿接口（最小面）
/// @notice `Settlement` 只依赖这 5 个方法：封盘状态、退款截止高度、集合承诺、退款入口、批量落账。
///         公开档（`OrderBook`）与密封档（`SealedOrderBook`）因此可以共用同一个结算合约，
///         而结算层始终不读取任何订单内容。
/// @dev 为什么把依赖从具体合约改成接口：密封档的订单簿只存承诺/密文，无法复用 `OrderBook` 的
///      明文存储；若让 `Settlement` 继续依赖具体类型，就必须改结算层才能接入。
///      本接口把改动限制在**依赖类型**上，`Settlement` 的校验顺序与控制流一行未动（见 `docs/05` §40）。
interface IOrderBook {
    /// @notice 某批次是否已封盘。
    function isSealed(uint64 epoch) external view returns (bool);

    /// @notice 回执提交截止高度；越过它用户可取回资产。
    function epochDeadlineBlock(uint64 epoch) external view returns (uint256);

    /// @notice 封盘时保存的订单集合承诺。
    function orderSetHashOf(uint64 epoch) external view returns (bytes32);

    /// @notice 结算触发的退款。仅结算合约可调用。
    /// @dev Settlement forwards the original external caller so an arbitrary third party cannot force a refund.
    function refundOnSettlement(bytes32 orderId, address requester) external;

    /// @notice 批量落账：把成交数量转给求解者，剩余退回用户。
    function settleBatch(bytes32[] calldata orderIds, uint256[] calldata amountSolds, address solver) external;

    /// @notice 本档的封盘集合是否提供**明文订单有效期**（档位无关的时限校验的数据来源）。
    /// @dev 公开档：`true`（内容明文在链上，`Settlement` 可逐单校验 `validUntil`）；
    ///      密封档：`false`（有效期属**密文内容**，链上只有承诺——由该档验证器在揭示时强制，
    ///      见 `SealedMatchVerifier` 里对 `opening.validUntil` 的校验）。
    ///      这条**必须显式声明**：静默返回空集合会让"结算窗口/有效期"校验悄悄消失。
    function exposesPlaintextValidity() external view returns (bool);

    /// @notice 仅当 `exposesPlaintextValidity() == true` 时可用：本批封盘集合的明文订单内容。
    /// @dev 不提供明文的档调用此方法一律 revert（而不是返回空数组），避免调用方误以为"没有过期单"。
    function epochOrderContents(uint64 epoch) external view returns (Order[] memory orders);
}
