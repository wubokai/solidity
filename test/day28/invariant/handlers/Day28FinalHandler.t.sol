// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../../lib/forge-std/src/Test.sol";
import "../../../../src/day28/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../../../src/day28/mocks/MockERC20.sol";
import "../../../../src/day28/mocks/FixedPriceOracle.sol";

contract Day28FinalHandler is Test {

    MiniLendingMC_BadDebt_TWAP_Day27 public lending;
    MockERC20 public stable;
    MockERC20 public weth;
    FixedPriceOracle public stableOracle;
    FixedPriceOracle public wethOracle;

    address[] public actors;

    uint256 public constant WAD = 1e18;

    constructor(
        MiniLendingMC_BadDebt_TWAP_Day27 _lending,
        MockERC20 _stable,
        MockERC20 _weth,
        FixedPriceOracle _stableOracle,
        FixedPriceOracle _wethOracle
    ) {
        lending = _lending;
        stable = _stable;
        weth = _weth;
        stableOracle = _stableOracle;
        wethOracle = _wethOracle;

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA1));
        actors.push(address(0xD0D));
        actors.push(address(0xE11));

        uint256 seedStable = 5_000_000e18;
        uint256 seedWeth = 5_000e18;

        for (uint256 i = 0; i < actors.length; i++) {
            stable.mint(actors[i], seedStable);
            weth.mint(actors[i], seedWeth);

            vm.startPrank(actors[i]);
            stable.approve(address(lending), type(uint256).max);
            weth.approve(address(lending), type(uint256).max);
            vm.stopPrank();
        }

    }

    function actorCount() external view returns(uint256){
        return actors.length;
    }

    function getActor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1e6, 50_000e18);

        vm.startPrank(user);
        

    }







    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

}