// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { BatchSettlement } from "../types/BexTypes.sol";

/// @title 撮合有效性验证器接口（按档位实现）
/// @notice 第一版只有公开档实现（`PlaintextMatchVerifier`）；密封档与密文档各自新增一个实现接入，
///         不需要修改 `Settlement` 的业务逻辑。这与 `IAttestationVerifier` 的预留方式同构：
///         回执证明"求解者已在目标链付款"，`matchProof` 证明"这批撮合是有效的"，两者互不替代。
/// @dev 见 `docs/09-档位预留接口规范.md` 第三节。接口只返回 `volume`：结算层真正需要的撮合输出
///      只有"成交了多少 base"（记账守恒用），价格与分配明细都属于撮合层内部，不越过边界。
interface IMatchVerifier {
    /// @notice 校验本批次的撮合结果。失败必须 revert（不得返回 false）。
    /// @param batch  结算载荷
    /// @param matchProof 该档位的有效性证明：
    ///        公开档 → 空字节（有效性由重算本身给出）
    ///        密封档 → 门限解密证书 / 揭示证明
    ///        密文档 → 解密正确性证明或 zkFHE 证明
    /// @return volume 本批次成交的 base 数量，供结算层做记账守恒校验
    function verifyMatch(BatchSettlement calldata batch, bytes calldata matchProof)
        external
        view
        returns (uint256 volume);
}
