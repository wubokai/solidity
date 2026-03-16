// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFlashLoanReceiver} from "./FlashLoanMock.sol";

contract NoRepayReceiverMock is IFlashLoanReceiver {
    function onFlashLoan(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override {
        // intentionally do nothing
    }
}