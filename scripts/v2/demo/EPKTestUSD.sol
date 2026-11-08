// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title EPK test stablecoin for the guard demo — TESTNET ONLY, no value
/// @notice Only the deployer can mint, so nobody else can move the demo pool's price.
contract EPKTestUSD is ERC20 {
    address public immutable minter;

    error NotMinter();

    constructor() ERC20("EPK Test USD", "tUSD") {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}
