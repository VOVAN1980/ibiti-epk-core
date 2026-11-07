// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";

contract TestToken is ERC20 {
    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Token that signals failure by returning false instead of reverting.
contract FalseToken {
    function balanceOf(address) external pure returns (uint256) {
        return 1_000e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// Router-like contract that pulls tokens with its allowance and sends them anywhere.
contract MockRouter {
    function pull(address token, address from, address to, uint256 amount) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// Minimal ERC-1271 wallet (stands in for a multisig / MPC signer).
contract Mock1271Wallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec,,) = ECDSA.tryRecover(hash, sig);
        return rec == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// Contract whose fallback echoes calldata: a sloppy 1271 check would accept any signature.
contract EchoWallet {
    fallback() external {
        assembly {
            calldatacopy(0, 0, calldatasize())
            return(0, calldatasize())
        }
    }
}

/// Validator that rejects everything (reverts must bubble unchanged).
contract RejectAllValidator {
    error Rejected();

    function validate(uint256, address, address, address, uint256, bytes calldata) external pure {
        revert Rejected();
    }
}

/// Target that tries to re-enter the vault during execution.
contract ReentrantTarget {
    function attack(address vault) external {
        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(address(this), 0, abi.encodeCall(this.attack, (vault)));
        EPKVault(payable(vault)).execute(0, calls, block.timestamp + 1, "", "");
    }
}
