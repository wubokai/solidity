// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Owned {
    error NotOwner();
    error NewOwnerZeroAddress();

    address public owner;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    constructor(address _owner) {
        if (_owner == address(0)) revert NewOwnerZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NewOwnerZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}