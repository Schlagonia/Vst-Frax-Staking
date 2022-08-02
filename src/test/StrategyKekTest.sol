// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
import "forge-std/console.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStaker } from "../interfaces/Frax/IStaker.sol";
import {StrategyParams} from "../interfaces/Vault.sol";

import {StrategyParams, IVault} from "../interfaces/Vault.sol";

contract StrategyKekTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testMaxKeks(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 10 ether && _amount < 10_000 ether);
        uint256 maxKeks =  strategy.maxKeks();
        console.log("max keks ", maxKeks);
        //Pick a number between 2 and 7 to test how many multiples of deposits to do 
        uint256 multiplier = (_amount % 5) + 2;

        for(uint256 i; i < (maxKeks * multiplier); i++) {
            tip(address(want), user, _amount);
            console.log("Depositing");
            depositToVault(user, vault, _amount);
            console.log("Deposited");
            // Harvest: Send funds through the strategy
            skip(1);
            console.log("Harvesting");
            strategy.harvest();
            console.log("harvested", i);
            //assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
            skip(toSkip);
        }

        uint256 deposited = (maxKeks * multiplier) * _amount;
        //IStaker.LockedStake[] memory stakes = staker.lockedStakesOf(address(strategy));
        assertEq(strategy.nextKek(), maxKeks * multiplier, "To many keks");
        assertGe(strategy.stakedBalance(), deposited, "Staked balance wrong");

        uint256 balanceBefore = want.balanceOf(address(user));
        vm_std_cheats.prank(user);
        vault.withdraw();
        
        assertGe(want.balanceOf(address(user)), balanceBefore + deposited, "not enough out");
    }

    function testSetMakKeks(uint256 _amount) public {
        vm_std_cheats.assume(_amount > 10 ether && _amount < 10_000 ether);
        uint256 maxKeks =  strategy.maxKeks();

        //Pick a number between 2 and 7 to test how many multiples of deposits to do 

        for(uint256 i; i < 6; i++) {
            tip(address(want), user, _amount);
            depositToVault(user, vault, _amount);

            // Harvest: Send funds through the strategy
            skip(1);
            strategy.harvest();
            //assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
            skip(toSkip);
        }

        uint256 newKeks = 7;
        vm_std_cheats.prank(strategist);
        strategy.setMaxKeks(newKeks);

        assertEq(strategy.maxKeks(), newKeks);

        for(uint256 i; i < 4; i++) {
            tip(address(want), user, _amount);
            depositToVault(user, vault, _amount);

            // Harvest: Send funds through the strategy
            skip(1);
            strategy.harvest();
            //assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, ONE_BIP_REL_DELTA);
            skip(toSkip);
        }

        assertEq(strategy.nextKek(), 7 + 4);
    }

}