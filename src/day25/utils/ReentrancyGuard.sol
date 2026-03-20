// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ReentrancyGuard {
    error Reentrancy();

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }
}