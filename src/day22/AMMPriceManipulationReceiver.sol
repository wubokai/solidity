// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFlashLoanReceiver} from "./FlashLoanMock.sol";

interface IERC20LikeManip {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMiniAMMSwapLike {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function swap0For1(
        uint256 amount0In,
        uint256 minAmount1Out,
        address to,
        uint256 ddl
    ) external returns (uint256 amount1Out);

    function swap1For0(
        uint256 amount1In,
        uint256 minAmount0Out,
        address to,
        uint256 ddl
    ) external returns (uint256 amount0Out);
}

contract AMMPriceManipulationReceiver is IFlashLoanReceiver {
    error UnauthorizedLender();
    error InvalidToken();
    error ApprovalFailed();
    error RepayFailed();


    enum Mode {
        Swap0For1,
        Swap1For0
    }

    struct Params {
        Mode mode;
        uint256 minOut;
        address to;
        uint256 deadline;
    }

    address public immutable lender;
    IMiniAMMSwapLike public immutable amm;
    address public immutable token0;
    address public immutable token1;

    constructor(address _lender, address _amm) {
        lender = _lender;
        amm = IMiniAMMSwapLike(_amm);
        token0 = amm.token0();
        token1 = amm.token1();
    }

    function onFlashLoan(
        address, // initiator
        address token,
        uint256 amount,
        bytes calldata data
    ) external override {
        if(msg.sender != lender) revert UnauthorizedLender();

        Params memory p = abi.decode(data,(Params));

        bool ok = IERC20LikeManip(token).approve(address(amm),amount);
        if(!ok) revert ApprovalFailed();

        if(p.mode == Mode.Swap0For1){
            if(token!=token0) revert InvalidToken();
            amm.swap0For1(amount, p.minOut, p.to, p.deadline);

        }else{
            if(token!=token1) revert InvalidToken();
            amm.swap1For0(amount, p.minOut, p.to, p.deadline);
        }

        ok = IERC20LikeManip(token).transfer(lender, amount);
        if(!ok) revert RepayFailed();

    }


}