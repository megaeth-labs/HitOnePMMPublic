// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 }            from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { HitOneStorage }     from "./HitOneStorage.sol";
import { HitOnePositions }   from "./HitOnePositions.sol";
import { HitOneAdmin }       from "./HitOneAdmin.sol";

/// @title HitOneMarket
/// @notice User-signed-order perp venue with permissionless, fully isolated per-maker sub-markets.
contract HitOneMarket is HitOnePositions, HitOneAdmin {
    constructor(address owner_, address usdm_)
        HitOneStorage(usdm_)
        Ownable(owner_)
        EIP712("HitOneMarket", "1")
    {
        // No initial maker: registration is permissionless. The owner curates tokens (setToken)
        // and the halter set; makers self-register by configuring risk + funding a pool.
    }
}
