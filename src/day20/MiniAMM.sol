// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

contract MiniAMM {
    error Expired();
    error InvalidAmount();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error InsufficientInputAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error SlippageExceeded();
    error TransferFailed();

    string public constant name = "MiniAMM LP Token";
    string public constant symbol = "MALP";
    uint8 public constant decimals = 18;

    IERC20Like public immutable token0;
    IERC20Like public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalSupply;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;

    uint256 public constant FEE_BPS = 30; // 0.30%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    event AddLiquidity(
        address indexed sender,
        address indexed to,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    event RemoveLiquidity(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(IERC20Like _token0, IERC20Like _token1 ){
        require(address(_token0) != address(_token1), "same token");
        token0 = _token0;
        token1 = _token1;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "burn exceeds balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function getReserves() external view returns(uint256, uint256){
        return (reserve0,reserve1);
    }

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure returns (uint256 amountB) {
        if (amountA == 0) revert InvalidAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountIn) {
        if (amountOut == 0) revert InvalidAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) revert InsufficientLiquidity();

        uint256 numerator = reserveIn * amountOut * BPS_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (BPS_DENOMINATOR - FEE_BPS);
        amountIn = (numerator / denominator) + 1; // round up
    }

    function addLiquidity(
        address to,
        uint256 amount0D,
        uint256 amount1D,
        uint256 amount0M,
        uint256 amount1M,
        uint256 ddl 
    ) external returns(uint256 amount0, uint256 amount1, uint256 shares){
        
        if(block.timestamp > ddl ) revert Expired();    
        if(amount0D == 0 || amount1D == 0) revert InvalidAmount();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        if(reserve0 == 0 && reserve1 == 0){
            amount0 = amount0D;
            amount1 = amount1D;

            shares = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            if(shares == 0) revert InsufficientLiquidityMinted();

            _safeTransferFrom(token0, msg.sender, address(this), amount0);
            _safeTransferFrom(token1, msg.sender, address(this), amount1);

            _mint(address(0),MINIMUM_LIQUIDITY);
            _mint(to, shares);

            _updateReserves();
            emit AddLiquidity(msg.sender, to, amount0, amount1, shares);
            return (amount0,amount1,shares);
        }

        uint256 amount1O = quote(amount0D,_reserve0,_reserve1);
        if(amount1O <= amount1D){
            if(amount1O< amount1M) revert SlippageExceeded();
            amount0 = amount0D;
            amount1 = amount1O;
        }else{
            uint256 amount0O = quote(amount1D,_reserve1,_reserve0);
            if(amount0O< amount0M) revert SlippageExceeded();   
            if(amount0O> amount0D) revert SlippageExceeded();   
            amount0 = amount0O;
            amount1 = amount1D;
        }

        if(amount0 < amount0M || amount1 < amount1M) revert SlippageExceeded();

        shares = _min((amount0 * totalSupply)/ _reserve0, (amount1 * totalSupply)/_reserve1);
        if(shares == 0) revert InsufficientLiquidityMinted();

        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);

        _mint(to, shares);
        _updateReserves();

        emit AddLiquidity(msg.sender, to, amount0, amount1, shares);
    }

    function removeLiquidity(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 ddl
    ) external returns(uint256 amount0, uint256 amount1){
        if (block.timestamp > ddl) revert Expired();
        if (shares == 0) revert InvalidAmount();
        if (totalSupply == 0) revert InsufficientLiquidity();

        amount0 = (shares * reserve0 ) /totalSupply;
        amount1 = (shares * reserve1 ) /totalSupply;

        if(amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if(amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        _burn(msg.sender, shares);

        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);
        _updateReserves();

        emit RemoveLiquidity(msg.sender, to, shares, amount0, amount1);
    }

    function swap0For1(
        uint256 amount0In,
        uint256 minAmount1Out,
        address to,
        uint256 ddl
    ) external returns (uint256 amount1Out) {
        if(block.timestamp > ddl) revert Expired();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        amount1Out = getAmountOut( amount0In, _reserve0, _reserve1);
        if(amount1Out < minAmount1Out) revert SlippageExceeded();

        _safeTransferFrom(token0, msg.sender, address(this), amount0In);
        _safeTransfer(token1, to, amount1Out);

        _updateReserves();

        emit Swap(msg.sender, address(token0), to, amount0In, amount1Out);
    }

    function swap1For0(
        uint256 amount1In,
        uint256 minAmount0Out,
        address to,
        uint256 ddl
    ) external returns (uint256 amount0Out) {

        if(block.timestamp > ddl) revert Expired();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        amount0Out = getAmountOut(amount1In, _reserve1, _reserve0);
        if(amount0Out < minAmount0Out) revert SlippageExceeded();

        _safeTransferFrom(token1, msg.sender, address(this), amount1In);
        _safeTransfer(token0, to, amount0Out);

        _updateReserves();

        emit Swap(msg.sender, address(token1), to, amount1In, amount0Out);

    }


    function _updateReserves() internal {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }

    function _safeTransfer(IERC20Like token, address to, uint256 amount) internal {
        bool ok = token.transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20Like token, address from, address to, uint256 amount) internal {
        bool ok = token.transferFrom(from, to, amount);
        if (!ok) revert TransferFailed();
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
