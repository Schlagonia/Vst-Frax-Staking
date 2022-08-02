// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

contract StrategyTriggerTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testHarvestTrigger(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 1 ether && _amount < 100_000 ether);

        // Deposit to the vault
        depositToVault(user, vault, _amount);
        assertEq(want.balanceOf(address(vault)), _amount);
        
        uint256 bal = want.balanceOf(user);
        if (bal > 0) {
            vm_std_cheats.prank(user);
            want.transfer(address(123), bal);
        }

        //Set max report delay to max for test
        strategy.setMaxReportDelay(type(uint256).max);
        
        //Nohings happened yet should be false
        assertTrue(!strategy.harvestTrigger(1));
        
        skip(1);
        // Harvest 1: Send funds through the strategy
        strategy.harvest();
        
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
        
        assertEq(want.balanceOf(address(strategy)), 0);
        
        skip(toSkip);
    
        console.log("Claimable Profit ", strategy.getClaimableProfit());
        strategy.setKeeperStuff(
            strategy.harvestProfitMax(),
            1
        );
        //min harvest 0 so any interest earned will make it true
        assertTrue(strategy.harvestTrigger(1), "Min harvest not triggereed");

        strategy.setKeeperStuff(
            strategy.harvestProfitMax(),
            type(uint256).max
        );

        //Min harvest should now be false
        assertTrue(!strategy.harvestTrigger(1), "Min Harvest Failed");

        strategy.setForceHarvestTriggerOnce(true);
        assertTrue(strategy.harvestTrigger(100), "Harves triggerForce");
     
        strategy.setForceHarvestTriggerOnce(false);
        
        //Tip and set max profit
        tip(address(FXS), address(strategy), 10 ether);
        strategy.setKeeperStuff(
            0,
            strategy.harvestProfitMin()
        );
        skip(1);
        assertTrue(strategy.harvestTrigger(100), "above max profit");

        vm_std_cheats.prank(user);
        vault.withdraw();
        assertEq(want.balanceOf(user), _amount, "User balance wrong");
    }

}
