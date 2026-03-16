// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFlashLoanReceiver} from "./FlashLoanMock.sol";

interface IERC20LikeReceiver {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract RepayOnlyReceiverMock is IFlashLoanReceiver {
    error TransferFailed();

    function onFlashLoan(
        address, // initiator
        address token,
        uint256 amount,
        bytes calldata // data
    ) external override {
        bool ok = IERC20LikeReceiver(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
    }
}