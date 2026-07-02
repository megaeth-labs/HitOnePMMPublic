// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 }            from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { HitOneStorage }     from "./HitOneStorage.sol";
import { HitOnePositions }   from "./HitOnePositions.sol";
import { HitOneAdmin }       from "./HitOneAdmin.sol";

/// @title HitOneMarket
/// @notice User-signed-order + maker-submitted perp venue.
contract HitOneMarket is HitOnePositions, HitOneAdmin {
    constructor(address owner_, address maker_, address usdm_)
        HitOneStorage(usdm_)
        Ownable(owner_)
        EIP712("HitOneMarket", "1")
    {
        if (maker_ != address(0)) {
            isMaker[maker_] = true;
            emit MakerSet(maker_, true);
        }
    }
}
