// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

contract ForceSend {

    constructor() payable{}

    function forceSend(address payable target) external{
        selfdestruct(payable(target));
    }

}