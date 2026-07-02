// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Minimal mintable ERC20 used as USDM in tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDM", "USDM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
