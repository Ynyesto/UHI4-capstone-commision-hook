// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockDOC is ERC20 {
    constructor() ERC20("DOC", "DOC", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}