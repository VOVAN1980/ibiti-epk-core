// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockTarget {
    uint256 public x;
    event XSet(uint256 x);

    function setX(uint256 _x) external payable {
        x = _x;
        emit XSet(_x);
    }
}