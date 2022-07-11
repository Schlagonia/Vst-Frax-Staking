// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use
pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Extended} from "./interfaces/IERC20Extended.sol";

import { ICurveFi } from "./interfaces/Curve/ICurveFi.sol";
import { IBalancerVault } from "./interfaces/Balancer/IBalancerVault.sol";
import { IBalancerPool } from "./interfaces/Balancer/IBalancerPool.sol";
import { IAsset } from "./interfaces/Balancer/IAsset.sol";
import { IUniswapV2Router02 } from "./interfaces/Uni/IUniswapV2Router02.sol";
import { IStaker } from "./interfaces/Frax/IStaker.sol";
import "./interfaces/WETH/IWETH9.sol";

contract CurveFraxVst is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    //LP Tokens
    IERC20 public constant VST =
        IERC20(0x64343594Ab9b56e99087BfA6F2335Db24c2d1F17);
    IERC20 public constant FRAX = 
        IERC20(0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F);

    //Reward Tokens
    IERC20 internal constant VSTA =
        IERC20(0xa684cd057951541187f288294a1e1C2646aA2d24);
    IERC20 internal constant FXS = 
        IERC20(0x9d2F299715D94d8A7E6F5eaa8E654E8c74a988A7);
    
    //For swaping
    IWETH9 internal constant WETH =
        IWETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    // USDC used for swaps routing
    address internal constant usdc =
        address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

    //Balancer addresses for VSTA swaps
    IBalancerVault internal constant balancerVault =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address private constant vstaPool = address(0xC61ff48f94D801c1ceFaCE0289085197B5ec44F0);
    bytes32 public immutable vstaPoolId;
    address private constant wethUsdcPool = address(0x64541216bAFFFEec8ea535BB71Fbc927831d0595);
    bytes32 public immutable wethUsdcPoolId;
    address private constant usdcVstPool = address(0x5A5884FC31948D59DF2aEcCCa143dE900d49e1a3);
    bytes32 public immutable usdcVstPoolId;
    //needed for swaps not to fail
    uint256 public minVsta = 1e15;

    //Frax addresses and variables for staking and swapping
    IStaker public constant staker =
        IStaker(0x127963A74c07f72D862F2Bdc225226c3251BD117);
    IUniswapV2Router02 public constant fraxRouter =
        IUniswapV2Router02(0xc2544A32872A91F4A553b404C6950e89De901fdb);
    //FXS/FRAX pool address used for harvest Trigger calculations
    address private constant fraxPair =
        address(0x053B92fFA8a15b7db203ab66Bbd5866362013566);
    //Need for staking. Locks the tokens for the minumum amount of time.
    uint256 public minLockTime; 

    //Curve pool and indexs
    ICurveFi internal constant curvePool =
        ICurveFi(0x59bF0545FCa0E5Ad48E13DA269faCD2E8C886Ba4);
    uint256 internal constant vstIndex = 0;
    uint256 internal constant fraxIndex = 1;

    uint256 public lastDeposit = 0;
    uint256 public lastDepositAmount;

    //Keeper stuff
    uint256 public maxBaseFee;
    bool public forceHarvestTriggerOnce = false;
    uint256 public harvestProfitMax;
    uint256 public harvestProfitMin;

    uint256 private immutable wantDecimals;
    uint256 private immutable minWant;
    uint256 public immutable maxSingleInvest;

    constructor(address _vault) BaseStrategy(_vault) {
        require(staker.stakingToken() == want, "Wrong want for staker");

        //Set Balancer Pool Ids
        vstaPoolId = IBalancerPool(vstaPool).getPoolId();
        wethUsdcPoolId = IBalancerPool(wethUsdcPool).getPoolId();
        usdcVstPoolId = IBalancerPool(usdcVstPool).getPoolId();

        //Set initial Keeper stuff
        maxBaseFee = 10e9;
        harvestProfitMax = type(uint256).max;
        harvestProfitMin = 0;

        wantDecimals = IERC20Extended(address(want)).decimals();
        minWant = 10 ** (wantDecimals - 3);
        maxSingleInvest = 10 ** (wantDecimals + 7);

        minLockTime = staker.lock_time_min();

        handleApprovals();
    }

    function handleApprovals() internal {
        //Approve want to staking contract
        want.safeApprove(address(staker), type(uint256).max);

        //approve both underlying tokens to curve Pool
        VST.safeApprove(address(curvePool), type(uint256).max);
        FRAX.safeApprove(address(curvePool), type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external pure override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "VstFraxStaker";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function stakedBalance() public view returns (uint256) {
        return staker.lockedLiquidityOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        unchecked {
            return balanceOfWant() + stakedBalance();
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
       _profit = 0;
        _loss = 0; 
        _debtPayment = 0;

        harvester();

        //get base want balance
        uint256 wantBalance = want.balanceOf(address(this));

        uint256 balance = wantBalance + stakedBalance();

        //get amount given to strat by vault
        uint256 debt = vault.strategies(address(this)).totalDebt;

        //Balance - Total Debt is profit
        if (balance >= debt) {
            uint256 needed;
            unchecked{
                _profit = balance - debt;
                needed = _profit + _debtOutstanding;
            }
            if (needed > wantBalance) {
                //Only gets called on harvest, which should be more that oneDay since last deposit so we should be liquid
                withdrawSome(needed - wantBalance);

                wantBalance = want.balanceOf(address(this));

                if (wantBalance < needed) {
                    if (_profit < wantBalance) {
                        _profit = wantBalance;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min((wantBalance - _profit), _debtOutstanding);
                    }
                } else {
                    _debtPayment = _debtOutstanding;
                }
            } else {
                _debtPayment = _debtOutstanding;
            }
        } else {
            _loss = debt - balance;
            if (_debtOutstanding > wantBalance) {
                //Only gets called on harvest which should be more that one Day apart so we dont need to check liquidity
                withdrawSome(_debtOutstanding - wantBalance);
                wantBalance = want.balanceOf(address(this));
            }
            _debtPayment = Math.min(wantBalance, _debtOutstanding);
        }

        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        //we are spending all our cash unless we have debt outstanding
        uint256 _wantBal = balanceOfWant();
        if (_wantBal < _debtOutstanding) {

            //Only gets called on harvest which should be more that oneDay apart so we should be liquid
            withdrawSome(_debtOutstanding - _wantBal);
            _wantBal = balanceOfWant();
            
            //An entire Kek must be removed for any withdraws so its likely we will over withdraw and need to reinvest the extra
            if(_wantBal > _debtOutstanding + minWant) {
                depositSome(_wantBal - _debtOutstanding);
            }
            return;
        }

        uint256 _wantToInvest = Math.min((_wantBal - _debtOutstanding), maxSingleInvest);
        //stake
        depositSome(_wantToInvest);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 needed;
        unchecked {
            needed = _amountNeeded - _liquidWant;
        } 
   
        //Need to check that their is enough liquidity to withdraw so we dont report loss thats not true
        if(lastDeposit + minLockTime > block.timestamp) {
            require(stakedBalance() - lastDepositAmount >= needed, "Need to wait till most recent deposit unlocks");
        }

        withdrawSome(needed);

        _liquidWant = balanceOfWant();

        unchecked {

            if (_liquidWant >= _amountNeeded) {
                _liquidatedAmount = _amountNeeded;
            } else {
                _liquidatedAmount = _liquidWant;
                _loss = _amountNeeded - _liquidWant;
            }
        }
    }

    function depositSome(uint256 _amount) internal {
        if(_amount < minWant) return;

        staker.stakeLocked(_amount, minLockTime);
        lastDeposit = block.timestamp;
        lastDepositAmount = _amount;
    }

    function withdrawSome(uint256 _amount) internal {
        if(_amount == 0) return;

        IStaker.LockedStake[] memory stakes = staker.lockedStakesOf(address(this));

        uint256 i = 0;
        uint256 needed = _amount;
        uint256 length = stakes.length;
        IStaker.LockedStake memory stake;
        uint256 liquidity;
        while(needed > 0 && i < length) {
            stake = stakes[i];
            liquidity = stake.amount;
         
            if(liquidity > 0 && stake.ending_timestamp <= block.timestamp) {
      
                staker.withdrawLocked(stake.kek_id);

                if(liquidity < needed) {
                    unchecked {
                        needed -= liquidity;
                        i ++;
                    }
                } else {
                    break;
                }
            } else {
                unchecked{
                    i++;
                }
            }
        }
    }

    function harvester() internal {
        if(staker.lockedLiquidityOf(address(this)) > 0) {
            staker.getReward();
        }
        swapFxsToFrax();
        swapVstaToVst();
        addCurveLiquidity();
    }

    function swapFxsToFrax() internal {
        uint256 fxsBal = FXS.balanceOf(address(this));

        if(fxsBal == 0) return;

        ///Swap to FRAX
        _checkAllowance(
            address(fraxRouter), 
            address(FXS), 
            fxsBal
        );

        address[] memory path = new address[](2);
        path[0] = address(FXS);
        path[1] = address(FRAX);

        fraxRouter.swapExactTokensForTokens(
            fxsBal, 
            0, 
            path, 
            address(this), 
            block.timestamp
            );
    }

    function swapVstaToVst() internal {
        _sellVSTAforWeth();
        _sellWethForVST();
    }

    function _sellVSTAforWeth() internal {
        uint256 _amountToSell = VSTA.balanceOf(address(this));
   
        if(_amountToSell < minVsta) return;

        _checkAllowance(
            address(balancerVault),
            address(VSTA),
            _amountToSell
        );

        //single swap balancer from vsta to weth
        IBalancerVault.SingleSwap memory singleSwap =
            IBalancerVault.SingleSwap(
                vstaPoolId,
                IBalancerVault.SwapKind.GIVEN_IN,
                IAsset(address(VSTA)),
                IAsset(address(WETH)),
                _amountToSell,
                abi.encode(0)
                );  

        IBalancerVault.FundManagement memory fundManagement =
            IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );

        balancerVault.swap(
            singleSwap,
            fundManagement,
            0,
            block.timestamp
        );        
    }

    function _sellWethForVST() internal {
        uint256 wethBalance = WETH.balanceOf(address(this));
 
        if(wethBalance == 0) return;

        _checkAllowance(address(balancerVault), address(WETH), wethBalance);

        //Batch swap from WETH -> USDC -> VST
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);

        swaps[0] = IBalancerVault.BatchSwapStep(
                wethUsdcPoolId,
                0,
                1,
                wethBalance,
                abi.encode(0)
            );

        swaps[1] = IBalancerVault.BatchSwapStep(
                usdcVstPoolId,
                1,
                2,
                0,
                abi.encode(0)
            );

        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(WETH));
        assets[1] = IAsset(usdc);
        assets[2] = IAsset(address(VST));

        IBalancerVault.FundManagement memory fundManagement =
            IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );
        
        int[] memory limits = new int[](3);
        limits[0] = int(wethBalance);
            
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            fundManagement, 
            limits, 
            block.timestamp
            );
    }

    function addCurveLiquidity() internal {
        uint256 fraxBal = FRAX.balanceOf(address(this));
        uint256 vstBal = VST.balanceOf(address(this));

        if(fraxBal == 0 && vstBal == 0) return;
    
        uint256[2] memory amounts;
        amounts[fraxIndex] = fraxBal;
        amounts[vstIndex] = vstBal;

        curvePool.add_liquidity(amounts, 0);
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = IERC20(_token).allowance(
            address(this),
            _contract
        );
        if (_currentAllowance < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _contract,
                _amount - _currentAllowance
            );
        }
    }

    //Will liquidate as much as possible at the time. May not be able to liquidate all if anything has been deposited in the last day
    // Would then have to be called again after locked period has expired
    function liquidateAllPositions() internal override returns (uint256) {
        withdrawSome(type(uint256).max);
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        require(lastDeposit + minLockTime < block.timestamp, "Lastest deposit is not avialable yet for withdraw");
        withdrawSome(type(uint256).max);
    
        uint256 fxsBal = FXS.balanceOf(address(this));
        if(fxsBal > 0 ) {
            FXS.safeTransfer(_newStrategy, fxsBal);
        }
        uint256 vstaBal = VSTA.balanceOf(address(this));
        if(vstaBal > 0) {
            VSTA.safeTransfer(_newStrategy, vstaBal);
        }
    }

    function protectedTokens()
        internal
        pure
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](4);
        protected[0] = address(VST);
        protected[1] = address(FRAX);
        protected[2] = address(VSTA);
        protected[3] = address(FXS);

        return protected;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest automagically
    function harvestTrigger(uint256 /*callCostinEth*/)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = getClaimableProfit();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (getBaseFee() > maxBaseFee) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    //Returns the estimated claimable profit in want. 
    function getClaimableProfit() public view returns (uint256 _claimableProfit) {
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        //Only use the Frax rewards
        (uint256 fxsEarned, ) = staker.earned(address(this));

        uint256 estimatdRewards = 0;
        if(fxsEarned > 0 ) {
            
            uint256 fxsToFrax = fraxRouter.getAmountOut(
                fxsEarned, 
                FXS.balanceOf(fraxPair), 
                FRAX.balanceOf(fraxPair)
            );
        
            uint256[2] memory amounts;
            amounts[fraxIndex] = fxsToFrax;
            amounts[vstIndex] = 0;

            estimatdRewards = curvePool.calc_token_amount(amounts, true);
        }

        assets += estimatdRewards;
        _claimableProfit = assets > debt ? assets - debt : 0;
    }

    function setKeeperStuff(
        uint256 _maxBaseFee, 
        uint256 _harvestProfitMax, 
        uint256 _harvestProfitMin
    ) external onlyGovernance {
        require(_maxBaseFee > 0, "Cant be 0");
        maxBaseFee = _maxBaseFee;
        harvestProfitMax = _harvestProfitMax;
        harvestProfitMin = _harvestProfitMin;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    function getBaseFee() public view returns (uint256) {
        return block.basefee;
    }

}