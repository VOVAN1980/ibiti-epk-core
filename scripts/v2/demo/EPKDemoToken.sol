// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title EPK demo token — TESTNET ONLY, no value
/// @notice Anyone can mint. Used to show EPK v2 limits and sessions on BSC testnet.
contract EPKDemoToken is ERC20 {
    constructor() ERC20("EPK Demo USD", "eUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
