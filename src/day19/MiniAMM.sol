// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MiniAMM {
    address public immutable token0;
    address public immutable token1;


    uint256 public reserve0;
    uint256 public reserve1;
    
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;
    
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;
    
    error ZeroAddress();
    error SameToken();
    error ZeroAmount();
    error InvalidToken();   
    error InvalidRatio();
    error InsufficientLiquidity();
    error InsufficientShares();
    error InsufficientOutput();
    error TransferFailed();

    
    event AddLiquidity(
        address indexed provider,
        uint256 amount0In,
        uint256 amount1In,
        uint256 sharesMint
    );

    event RemoveLiquidity(
        address indexed provider,
        uint256 sharesBurned,
        uint256 amount0Out,
        uint256 amount1Out
    );

    event Swap(
        address indexed trader,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut
    );

    constructor (address _token0, address _token1) {
        if(_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        if(_token0 == _token1) revert SameToken();

        token0 = _token0;
        token1 = _token1;
    }

    function addLiquidity(uint256 amount0, uint256 amount1 ) external returns(uint256 shares) {
        if(amount0 == 0 || amount1 == 0) revert ZeroAmount();
        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);

        if(totalShares == 0){
            shares = _sqrt(amount0 * amount1);
            if(shares == 0) revert InsufficientLiquidity();
        }else{
            if(amount0 * reserve1 != amount1 * reserve0 ) revert InvalidRatio();

            uint256 shares0 = (amount0 * totalShares) / reserve0;
            uint256 shares1 = (amount1 * totalShares) / reserve1;
            shares = _min(shares0, shares1);

            if(shares == 0) revert InsufficientLiquidity();
        }

        balanceOf[msg.sender] += shares;
        totalShares += shares;

        _updateReserves();

        emit AddLiquidity(msg.sender, amount0, amount1, shares);

    }

    function removeLiquidity(uint256 sharesIn)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        if(sharesIn == 0) revert ZeroAmount();
        if( balanceOf[msg.sender] < sharesIn ) revert InsufficientShares();
        if(totalShares == 0) revert InsufficientLiquidity();

        amount0Out = (sharesIn * reserve0) / totalShares;
        amount1Out = (sharesIn * reserve1) / totalShares;

        if(amount0Out ==0 || amount1Out == 0) revert InsufficientLiquidity();

        totalShares -= sharesIn;
        balanceOf[msg.sender] -= sharesIn;

        _safeTransfer(token0, msg.sender, amount0Out);
        _safeTransfer(token1, msg.sender, amount1Out);

        _updateReserves();

        emit RemoveLiquidity(msg.sender, sharesIn, amount0Out, amount1Out);
    }

    function swap0For1(uint256 amount0In, uint256 minAmount1Out)
        external
        returns (uint256 amount1Out)
    {
        if(amount0In == 0) revert ZeroAmount();
        if(reserve0 ==0 || reserve1 == 0) revert InsufficientLiquidity();
        
        amount1Out = _getAmountOut(amount0In, reserve0, reserve1);
        if(amount1Out < minAmount1Out) revert InsufficientOutput();
        if(amount1Out >= reserve1) revert InsufficientLiquidity();

        _safeTransferFrom(token0, msg.sender, address(this), amount0In);
        _safeTransfer(token1, msg.sender, amount1Out);

        _updateReserves();

        emit Swap(msg.sender, token0, amount0In, token1, amount1Out);
    }

    function swap1For0(uint256 amount1In, uint256 minAmount0Out)
        external
        returns (uint256 amount0Out)
    {
        if (amount1In == 0) revert ZeroAmount();
        if (reserve0 == 0 || reserve1 == 0) revert InsufficientLiquidity();

        amount0Out = _getAmountOut(amount1In, reserve1, reserve0);
        if (amount0Out < minAmount0Out) revert InsufficientOutput();
        if (amount0Out >= reserve0) revert InsufficientLiquidity();

        _safeTransferFrom(token1, msg.sender, address(this), amount1In);
        _safeTransfer(token0, msg.sender, amount0Out);

        _updateReserves();

        emit Swap(msg.sender, token1, amount1In, token0, amount0Out);
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        if (tokenIn == token0) {
            if (reserve0 == 0 || reserve1 == 0) revert InsufficientLiquidity();
            amountOut = _getAmountOut(amountIn, reserve0, reserve1);
        } else if (tokenIn == token1) {
            if (reserve0 == 0 || reserve1 == 0) revert InsufficientLiquidity();
            amountOut = _getAmountOut(amountIn, reserve1, reserve0);
        } else {
            revert InvalidToken();
        }
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (reserveOut * amountInWithFee) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    function _updateReserves() internal {
        reserve0 = IERC20Like(token0).balanceOf(address(this));
        reserve1 = IERC20Like(token1).balanceOf(address(this));
    }


    function _safeTransfer(address token, address to, uint256 amount) internal {
        bool ok = IERC20Like(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }


    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        bool ok = IERC20Like(token).transferFrom(from, to, amount);
        if(!ok) revert TransferFailed();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        if (y <= 3) return 1;

        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }
}
