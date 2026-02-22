// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}