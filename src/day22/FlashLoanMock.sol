// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20LikeFlash {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface IFlashLoanReceiver {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        bytes calldata data
    ) external;
}


contract FlashLoanMock {
    error InvalidAmount();
    error InsufficientLiquidity();
    error TransferFailed();
    error NotRepaid();

    event FlashLoan(
        address indexed initiator,
        address indexed receiver,
        address indexed token,
        uint256 amount
    );

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external {
        if(amount == 0) revert InvalidAmount();

        uint256 balanceBefore = IERC20LikeFlash(token).balanceOf(address(this));
        if(balanceBefore < amount) revert InsufficientLiquidity();

        _safeTransfer(token, receiver, amount);
        IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, token, amount, data);

        uint256 balanceAfter = IERC20LikeFlash(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert NotRepaid();

        emit FlashLoan(msg.sender, receiver, token, amount);
    }


    function _safeTransfer(address token, address to, uint256 amount) internal {
        bool ok = IERC20LikeFlash(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

}
