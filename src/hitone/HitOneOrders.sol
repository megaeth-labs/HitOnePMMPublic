// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ECDSA }             from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { HitOneStorage }     from "./HitOneStorage.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";

/// @title HitOneOrders
/// @notice User-signed-order verification and slippage-band checks.
abstract contract HitOneOrders is HitOneStorage {
    // ---- Order verification ----

    function _orderDigest(Order calldata o) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.user, o.maker, o.token, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce
        ));
        return _hashTypedDataV4(sh);
    }

    /// @dev Verify sig + consume nonce. The submitter MUST be the exact maker the user signed for
    /// (`o.maker`), so flow can't be stolen by another maker.
    function _verifyAndConsumeOrder(Order calldata o, bytes calldata sig) internal {
        if (msg.sender != o.maker) revert WrongMaker();
        if (block.timestamp > o.deadline) revert OrderExpired();
        if (nonceUsed[o.user][o.channel][o.nonce]) revert NonceAlreadyUsed();
        address signer = ECDSA.recover(_orderDigest(o), sig);
        if (signer != o.user) revert BadUserSig();
        nonceUsed[o.user][o.channel][o.nonce] = true;
        emit NonceUsed(o.user, o.channel, o.nonce);
    }

    /// @dev Enforce maker's fillPrice is within user's [targetPrice ± maxSlippageBps] band.
    function _checkSlippageBand(uint256 fillPrice, uint256 targetPrice, uint256 maxSlippageBps) internal pure {
        uint256 diff = fillPrice > targetPrice ? fillPrice - targetPrice : targetPrice - fillPrice;
        if (diff * ParamCatalog.BPS_DENOM > targetPrice * maxSlippageBps) revert SlippageExceeded();
    }

    /// @dev Open/increase band check with the open fee folded in. The fee (bps of notional) worsens
    /// the effective entry by `fillPrice × openFeeBps/1e4` — higher for a long, lower for a short —
    /// so the ALL-IN price must still sit inside the user's signed band. This bounds any maker fee
    /// by the user's own worst-price tolerance (the maker can't extract more than the user consented
    /// to), without a separate fee cap or an Order-struct change.
    function _checkSlippageBandWithFee(
        uint256 fillPrice, uint256 targetPrice, uint256 maxSlippageBps, bool isLong, uint256 openFeeBps
    ) internal pure {
        uint256 feeImpact = fillPrice * openFeeBps / ParamCatalog.BPS_DENOM;
        uint256 effective = isLong ? fillPrice + feeImpact : fillPrice - feeImpact;
        _checkSlippageBand(effective, targetPrice, maxSlippageBps);
    }
}
