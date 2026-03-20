// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Owned.sol";

contract PausableOwned is Owned {
    error Paused();
    error NotPaused();

    bool public paused;

    event PausedStateSet(bool isPaused);

    constructor(address _owner) Owned(_owner) {}

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert NotPaused();
        _;
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit PausedStateSet(true);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit PausedStateSet(false);
    }
}