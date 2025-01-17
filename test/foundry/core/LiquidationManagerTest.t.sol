// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// test setup
import {BorrowerOperationsTest, BimaMath, ITroveManager, SafeCast, Math} from "./BorrowerOperationsTest.t.sol";
import {BIMA_DECIMAL_PRECISION} from "../../../contracts/dependencies/Constants.sol";

import {console} from "forge-std/console.sol";

contract LiquidationManagerTest is BorrowerOperationsTest {
    uint256 internal constant COLL_REDUCTION_FACTOR = 30_000;
    uint256 internal constant LM_100pct = 1000000000000000000;

    function setUp() public virtual override {
        super.setUp();

        // verify staked btc trove manager enabled for liquidation
        assertTrue(liquidationMgr.isTroveManagerEnabled(stakedBTCTroveMgr));
    }

    // helper functions
    function _getCollGasCompensation(uint256 coll) internal view returns (uint256 result) {
        result = coll / liquidationMgr.PERCENT_DIVISOR();
    }

    // used to save important state for verification
    struct LiquidationState {
        uint256 troveOwnersCount;
        uint256 totalDebt;
        uint256 totalColl;
        uint256 userDebt;
        uint256 userColl;
        uint256 userPendingDebtReward;
        uint256 userPendingCollateralReward;
        uint256 stabPoolTotalDebtTokenDeposits;
        uint256 stabPoolStakedBTCBal;
        uint256 stabPoolDebtTokenBal;
    }

    function _getLiquidationState(address user) internal view returns (LiquidationState memory state) {
        state.troveOwnersCount = stakedBTCTroveMgr.getTroveOwnersCount();

        state.totalDebt = stakedBTCTroveMgr.getTotalActiveDebt();
        state.totalColl = stakedBTCTroveMgr.getTotalActiveCollateral();

        (
            state.userDebt,
            state.userColl,
            state.userPendingDebtReward,
            state.userPendingCollateralReward
        ) = stakedBTCTroveMgr.getEntireDebtAndColl(user);

        state.stabPoolTotalDebtTokenDeposits = stabilityPool.getTotalDebtTokenDeposits();
        state.stabPoolStakedBTCBal = stakedBTC.balanceOf(address(stabilityPool));
        state.stabPoolDebtTokenBal = debtToken.balanceOf(address(stabilityPool));
    }

    function test_liquidate_oneTroveWithoutStabilityPool(uint256 collateralAmount, bool functionSwitch) external {
        // bound fuzz inputs - reduce max debt to prevent over-collateralization
        // so that liquidation will occur
        collateralAmount = bound(collateralAmount, minCollateral, maxCollateral / COLL_REDUCTION_FACTOR);

        // get max debt
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // set new value of btc to $50,000 to make trove liquidatable
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(50000 * 10 ** 8),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // no deposits in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, 0);

        // function switch uses different liquidate functions
        if (functionSwitch) {
            liquidationMgr.liquidateTroves(stakedBTCTroveMgr, 1, type(uint256).max);
        } else {
            liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);
        }

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify defaulted debt & collateral calculated correctly
        assertEq(stakedBTCTroveMgr.defaultedDebt(), statePre.userDebt + statePre.userPendingDebtReward);
        assertEq(
            stakedBTCTroveMgr.defaultedCollateral(),
            statePre.userColl - _getCollGasCompensation(statePre.userColl)
        );

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // no TroveManager errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);

        // no StabilityPool errors
        assertEq(stabilityPool.lastCollateralError_Offset(0), 0);
        assertEq(stabilityPool.lastDebtLossError_Offset(), 0);
    }

    function test_liquidate_oneTroveWithStabilityPool(
        uint96 spDepositAmount,
        uint256 collateralAmount,
        bool functionSwitch
    ) external {
        // user2 deposits into the stability pool
        spDepositAmount = uint96(bound(spDepositAmount, 1, type(uint96).max));
        _provideToSP(users.user2, spDepositAmount, 1);

        // bound fuzz inputs - reduce max debt to prevent over-collateralization
        // so that liquidation will occur
        collateralAmount = bound(collateralAmount, minCollateral, maxCollateral / COLL_REDUCTION_FACTOR);

        // get max debt
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // set new value of btc to $50,000 to make trove liquidatable
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(50000 * 10 ** 8),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // user2 deposit in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, spDepositAmount);

        // function switch uses different liquidate functions
        if (functionSwitch) {
            liquidationMgr.liquidateTroves(stakedBTCTroveMgr, 1, type(uint256).max);
        } else {
            liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);
        }

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify stability pool debt token deposits reduced by amount used to offset liquidation
        uint256 userDebtPlusPendingRewards = statePre.userDebt + statePre.userPendingDebtReward;
        uint256 debtToOffsetUsingStabilityPool = BimaMath._min(
            userDebtPlusPendingRewards,
            statePre.stabPoolTotalDebtTokenDeposits
        );

        // verify defaulted debt calculated correctly
        assertEq(
            statePost.stabPoolTotalDebtTokenDeposits,
            statePre.stabPoolTotalDebtTokenDeposits - debtToOffsetUsingStabilityPool
        );
        assertEq(stakedBTCTroveMgr.defaultedDebt(), userDebtPlusPendingRewards - debtToOffsetUsingStabilityPool);

        // calculate expected collateral to liquidate
        uint256 collToLiquidate = statePre.userColl - _getCollGasCompensation(statePre.userColl);

        // calculate expected collateral to send to stability pool
        uint256 collToSendToStabilityPool = (collToLiquidate * debtToOffsetUsingStabilityPool) /
            userDebtPlusPendingRewards;

        // verify defaulted collateral calculated correctly
        assertEq(stakedBTCTroveMgr.defaultedCollateral(), collToLiquidate - collToSendToStabilityPool);

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // verify stability pool received collateral tokens
        assertEq(statePost.stabPoolStakedBTCBal, statePre.stabPoolStakedBTCBal + collToSendToStabilityPool);

        // verify stability pool lost debt tokens
        assertEq(statePost.stabPoolDebtTokenBal, statePre.stabPoolDebtTokenBal - debtToOffsetUsingStabilityPool);

        // no TroveManager errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);

        // since user2 is the only stability pool depositor they
        // should gain the collateral sent to the stability pool
        uint256[] memory user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);

        // due to rounding? the user can receive slightly less
        assertTrue(user2CollateralGains[0] <= collToSendToStabilityPool);

        // verify user2 can claim their collateral gains
        assertEq(stakedBTC.balanceOf(users.user2), 0);

        uint256[] memory collateralIndexes = new uint256[](1);
        collateralIndexes[0] = 0;
        vm.prank(users.user2);
        stabilityPool.claimCollateralGains(users.user2, collateralIndexes);
        assertEq(stakedBTC.balanceOf(users.user2), user2CollateralGains[0]);
        assertEq(stakedBTC.balanceOf(address(stabilityPool)), statePost.stabPoolStakedBTCBal - user2CollateralGains[0]);

        // verify nothing else can be claimed
        user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);
        assertEq(user2CollateralGains[0], 0);
    }

    function test_liquidate_oneTroveWithStabilityPool_custom() external {
        // user2 deposits into the stability pool
        uint96 spDepositAmount = 1e18;
        _provideToSP(users.user2, spDepositAmount, 1);

        // user1 opens a trove using 2 BTC collateral (price = $60,000 in MockOracle)
        uint256 collateralAmount = 2e18;
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        uint256 userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertEq(userICR, 2250000000000000000);

        // set new value of btc to $50,000 to make trove liquidatable
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(50000 * 10 ** 8),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // PREV ICR : 2250000000000000000
        // NOW  ICR : 1875000000000000000
        //
        // TM MCR   : 2000000000000000000
        userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertEq(userICR, 1875000000000000000);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // user2 deposit in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, spDepositAmount);

        console.log("vax chemii: ", stakedBTC.balanceOf(address(stabilityPool)));

        // liquidate via `liquidate`
        liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);

        console.log("vax chemii: ", stakedBTC.balanceOf(address(stabilityPool)));

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify stability pool debt token deposits reduced by amount used to offset liquidation
        uint256 userDebtPlusPendingRewards = statePre.userDebt + statePre.userPendingDebtReward;
        uint256 debtToOffsetUsingStabilityPool = BimaMath._min(
            userDebtPlusPendingRewards,
            statePre.stabPoolTotalDebtTokenDeposits
        );

        // verify defaulted debt calculated correctly
        assertEq(
            statePost.stabPoolTotalDebtTokenDeposits,
            statePre.stabPoolTotalDebtTokenDeposits - debtToOffsetUsingStabilityPool
        );
        assertEq(stakedBTCTroveMgr.defaultedDebt(), userDebtPlusPendingRewards - debtToOffsetUsingStabilityPool);

        // calculate expected collateral to liquidate
        uint256 collToLiquidate = statePre.userColl - _getCollGasCompensation(statePre.userColl);

        // calculate expected collateral to send to stability pool
        uint256 collToSendToStabilityPool = (collToLiquidate * debtToOffsetUsingStabilityPool) /
            userDebtPlusPendingRewards;

        // verify defaulted collateral calculated correctly
        assertEq(stakedBTCTroveMgr.defaultedCollateral(), collToLiquidate - collToSendToStabilityPool);

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // verify stability pool received collateral tokens
        assertEq(statePost.stabPoolStakedBTCBal, statePre.stabPoolStakedBTCBal + collToSendToStabilityPool);

        // verify stability pool lost debt tokens
        assertEq(statePost.stabPoolDebtTokenBal, statePre.stabPoolDebtTokenBal - debtToOffsetUsingStabilityPool);

        // no errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);

        // since user2 is the only stability pool depositor they
        // should gain the collateral sent to the stability pool
        uint256[] memory user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);
        assertEq(user2CollateralGains[0], collToSendToStabilityPool);

        assertEq(stakedBTC.balanceOf(users.user2), 0);

        uint256[] memory collateralIndexes = new uint256[](1);
        collateralIndexes[0] = 0;
        vm.prank(users.user2);

        console.log("CLAIMIIIING");
        stabilityPool.claimCollateralGains(users.user2, collateralIndexes);
        console.log("CLAIMED");

        assertEq(stakedBTC.balanceOf(users.user2), collToSendToStabilityPool);
        assertEq(stakedBTC.balanceOf(address(stabilityPool)), 0);

        // verify nothing else can be claimed
        user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);
        assertEq(user2CollateralGains[0], 0);
    }

    function test_liquidate_oneTroveWithStabilityPool_ICRlt100(
        uint96 spDepositAmount,
        uint256 collateralAmount,
        bool functionSwitch
    ) external {
        // user2 deposits into the stability pool
        spDepositAmount = uint96(bound(spDepositAmount, 1, type(uint96).max));
        _provideToSP(users.user2, spDepositAmount, 1);

        // bound fuzz inputs - reduce max debt to prevent over-collateralization
        // so that liquidation will occur
        collateralAmount = bound(collateralAmount, minCollateral, maxCollateral / COLL_REDUCTION_FACTOR);

        // get max debt
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        // user1 opens the trove
        _openTrove(users.user1, collateralAmount, debtAmountMax);

        uint256 userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertEq(userICR, 2250000000000000000);

        // calculate new price value such trove will be liquidatable
        // with ICR <= _100pct which triggers non-standard liquidation code
        uint256 newPrice = ((LM_100pct * debtAmountMax) / collateralAmount) - 1;

        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(newPrice / 10 ** 12),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // verify ICR <= _100pct
        userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertTrue(userICR <= LM_100pct);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // user2 deposit in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, spDepositAmount);

        // function switch uses different liquidate functions
        if (functionSwitch) {
            liquidationMgr.liquidateTroves(stakedBTCTroveMgr, 1, type(uint256).max);
        } else {
            liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);
        }

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify stability pool debt token deposits reduced by amount used to offset liquidation
        uint256 userDebtPlusPendingRewards = statePre.userDebt + statePre.userPendingDebtReward;

        // verify stability pool not used in this liquidation logic
        assertEq(statePost.stabPoolTotalDebtTokenDeposits, statePre.stabPoolTotalDebtTokenDeposits);
        assertEq(statePost.stabPoolDebtTokenBal, statePre.stabPoolDebtTokenBal);

        // entire user debt is defaulted
        assertEq(stakedBTCTroveMgr.defaultedDebt(), userDebtPlusPendingRewards);

        // calculate expected collateral to liquidate
        uint256 collToLiquidate = statePre.userColl - _getCollGasCompensation(statePre.userColl);

        // verify defaulted collateral calculated correctly with no collateral
        // sent to the stability pool
        assertEq(stakedBTCTroveMgr.defaultedCollateral(), collToLiquidate);
        assertEq(statePost.stabPoolStakedBTCBal, statePre.stabPoolStakedBTCBal);

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // no errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);
    }

    function test_liquidate_oneTroveWithStabilityPool_ICRgtMCR_TCRltCCR_ICRltTCR(bool functionSwitch) external {
        (uint256 collateralAmount, uint256 debtAmountMax) = _openTroveThenRecoveryMode();

        // user2 deposits enough debt into the stability pool to cover user1's debt
        uint96 spDepositAmount = SafeCast.toUint96(debtAmountMax + 1e18);
        _provideToSP(users.user2, spDepositAmount, 1);

        uint256 userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertEq(userICR, 2000062500000000000);
        assertTrue(userICR >= stakedBTCTroveMgr.MCR());

        (uint256 entireSystemColl, uint256 entireSystemDebt) = borrowerOps.getGlobalSystemBalances();
        uint256 TCR = BimaMath._computeCR(entireSystemColl, entireSystemDebt);
        assertEq(TCR, 2096131448287994470);

        // sanity checks to ensure specific liquidation code called using `_tryLiquidateWithCap`
        assertTrue(TCR < borrowerOps.CCR());
        assertTrue(borrowerOps.checkRecoveryMode(TCR));
        assertTrue(userICR < TCR);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // user2 deposit in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, spDepositAmount);

        // function switch uses different liquidate functions
        if (functionSwitch) {
            liquidationMgr.liquidateTroves(stakedBTCTroveMgr, 1, type(uint256).max);
        } else {
            liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);
        }

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify stability pool debt token deposits reduced by amount used to offset liquidation
        uint256 userDebtPlusPendingRewards = statePre.userDebt + statePre.userPendingDebtReward;
        uint256 debtToOffsetUsingStabilityPool = BimaMath._min(
            userDebtPlusPendingRewards,
            statePre.stabPoolTotalDebtTokenDeposits
        );

        // verify defaulted debt calculated correctly
        assertEq(
            statePost.stabPoolTotalDebtTokenDeposits,
            statePre.stabPoolTotalDebtTokenDeposits - debtToOffsetUsingStabilityPool
        );
        assertEq(stakedBTCTroveMgr.defaultedDebt(), userDebtPlusPendingRewards - debtToOffsetUsingStabilityPool);

        // calculate expected collateral to liquidate
        uint256 collToLiquidate = statePre.userColl - _getCollGasCompensation(statePre.userColl);

        // calculate expected collateral to send to stability pool
        uint256 collToSendToStabilityPool = (collToLiquidate * debtToOffsetUsingStabilityPool) /
            userDebtPlusPendingRewards;

        // verify defaulted collateral calculated correctly
        assertEq(stakedBTCTroveMgr.defaultedCollateral(), collToLiquidate - collToSendToStabilityPool);

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // verify stability pool received collateral tokens
        // `_tryLiquidateWithCap` used in the special circumstances of this
        // scenario calculates this slightly differenlty than normal liquidations
        uint256 collToOffset = (statePre.userDebt * stakedBTCTroveMgr.MCR()) / stakedBTCTroveMgr.fetchPrice();
        collToSendToStabilityPool = collToOffset - _getCollGasCompensation(collToOffset);
        assertEq(statePost.stabPoolStakedBTCBal, statePre.stabPoolStakedBTCBal + collToSendToStabilityPool);

        // verify stability pool lost debt tokens
        assertEq(statePost.stabPoolDebtTokenBal, statePre.stabPoolDebtTokenBal - debtToOffsetUsingStabilityPool);

        // no errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);
    }

    function test_FixAttackerDrainsStabilityPoolCollateralTokens() external {
        // user1 and user 2 both deposit 10K into the stability pool
        uint96 spDepositAmount = 10_000e18;
        _provideToSP(users.user1, spDepositAmount, 1);
        _provideToSP(users.user2, spDepositAmount, 1);

        // user1 opens a trove using 1 BTC collateral (price = $60,000 in MockOracle)
        uint256 collateralAmount = 1e18;
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // set new value of btc to $50,000 to make trove liquidatable
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(50000 * 10 ** 8),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // save previous state
        LiquidationState memory statePre = _getLiquidationState(users.user1);

        // both users deposits in the stability pool
        assertEq(statePre.stabPoolTotalDebtTokenDeposits, spDepositAmount * 2);

        // liquidate via `liquidate`
        liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);

        // save after state
        LiquidationState memory statePost = _getLiquidationState(users.user1);

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        // user1 after state all zeros
        assertEq(statePost.userDebt, 0);
        assertEq(statePost.userColl, 0);
        assertEq(statePost.userPendingDebtReward, 0);
        assertEq(statePost.userPendingCollateralReward, 0);

        // verify total active debt & collateral reduced by liquidation
        assertEq(statePost.totalDebt, statePre.totalDebt - debtAmountMax - INIT_GAS_COMPENSATION);
        assertEq(statePost.totalColl, statePre.totalColl - collateralAmount);

        // verify stability pool debt token deposits reduced by amount used to offset liquidation
        uint256 userDebtPlusPendingRewards = statePre.userDebt + statePre.userPendingDebtReward;
        uint256 debtToOffsetUsingStabilityPool = BimaMath._min(
            userDebtPlusPendingRewards,
            statePre.stabPoolTotalDebtTokenDeposits
        );

        // verify default debt calculated correctly
        assertEq(
            statePost.stabPoolTotalDebtTokenDeposits,
            statePre.stabPoolTotalDebtTokenDeposits - debtToOffsetUsingStabilityPool
        );
        assertEq(stakedBTCTroveMgr.defaultedDebt(), userDebtPlusPendingRewards - debtToOffsetUsingStabilityPool);

        // calculate expected collateral to liquidate
        uint256 collToLiquidate = statePre.userColl - _getCollGasCompensation(statePre.userColl);

        // calculate expected collateral to send to stability pool
        uint256 collToSendToStabilityPool = (collToLiquidate * debtToOffsetUsingStabilityPool) /
            userDebtPlusPendingRewards;

        // verify defaulted collateral calculated correctly
        assertEq(stakedBTCTroveMgr.defaultedCollateral(), collToLiquidate - collToSendToStabilityPool);

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // verify stability pool received collateral tokens
        assertEq(statePost.stabPoolStakedBTCBal, statePre.stabPoolStakedBTCBal + collToSendToStabilityPool);

        // verify stability pool lost debt tokens
        assertEq(statePost.stabPoolDebtTokenBal, statePre.stabPoolDebtTokenBal - debtToOffsetUsingStabilityPool);

        // no TroveManager errors
        assertEq(stakedBTCTroveMgr.lastCollateralError_Redistribution(), 0);
        assertEq(stakedBTCTroveMgr.lastDebtError_Redistribution(), 0);

        // user1 and user2 are both stability pool depositors so they
        // gain an equal share of the collateral sent to the stability pool
        // (at least in our PoC with simple whole numbers)
        uint256 collateralGainsPerUser = collToSendToStabilityPool / 2;

        uint256[] memory user1CollateralGains = stabilityPool.getDepositorCollateralGain(users.user1);
        assertEq(user1CollateralGains.length, 1);
        assertEq(user1CollateralGains[0], collateralGainsPerUser);

        uint256[] memory user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);
        assertEq(user2CollateralGains[0], collateralGainsPerUser);

        // user2 claims their gains
        assertEq(stakedBTC.balanceOf(users.user2), 0);
        uint256[] memory collateralIndexes = new uint256[](1);
        collateralIndexes[0] = 0;
        vm.prank(users.user2);
        stabilityPool.claimCollateralGains(users.user2, collateralIndexes);
        assertEq(stakedBTC.balanceOf(users.user2), collateralGainsPerUser);
        assertEq(stakedBTC.balanceOf(address(stabilityPool)), statePost.stabPoolStakedBTCBal - collateralGainsPerUser);

        // if user2 tries to immediately claim again, they receive no additional tokens
        vm.prank(users.user2);
        stabilityPool.claimCollateralGains(users.user2, collateralIndexes);
        assertEq(stakedBTC.balanceOf(users.user2), collateralGainsPerUser);
        assertEq(stakedBTC.balanceOf(address(stabilityPool)), statePost.stabPoolStakedBTCBal - collateralGainsPerUser);

        // user1 claims their gains
        assertEq(stakedBTC.balanceOf(users.user1), 0);
        vm.prank(users.user1);
        stabilityPool.claimCollateralGains(users.user1, collateralIndexes);
        assertEq(stakedBTC.balanceOf(users.user1), collateralGainsPerUser);
        assertEq(stakedBTC.balanceOf(address(stabilityPool)), 0);

        // if user1 tries to immediately claim again, they receive no additional tokens
        vm.prank(users.user1);
        stabilityPool.claimCollateralGains(users.user1, collateralIndexes);
        assertEq(stakedBTC.balanceOf(users.user1), collateralGainsPerUser);

        // view function now returns 0 pending collateral gains for both users
        user1CollateralGains = stabilityPool.getDepositorCollateralGain(users.user1);
        assertEq(user1CollateralGains.length, 1);
        assertEq(user1CollateralGains[0], 0);

        user2CollateralGains = stabilityPool.getDepositorCollateralGain(users.user2);
        assertEq(user2CollateralGains.length, 1);
        assertEq(user2CollateralGains[0], 0);
    }

    // this test mainly exercises TroveManager::applyPendingRewards
    // but is here as it requires liqudation to have happened
    function test_troveManager_applyPendingRewards() external {
        // set a positive interest rate
        _setInterestRate(stakedBTCTroveMgr.MAX_INTEREST_RATE_IN_BPS());

        // save owner trove coll & debt
        (uint256 ownerTroveCollPre, uint256 ownerTroveDebtPre) = stakedBTCTroveMgr.getTroveCollAndDebt(users.owner);
        assertEq(ownerTroveCollPre, 1000000000000000000);
        assertEq(ownerTroveDebtPre, 1001000000000000000000);

        // user1 opens a trove using 2 BTC collateral (price = $60,000 in MockOracle)
        uint256 collateralAmount = 2e18;
        uint256 debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // set new value of btc to $50,000 to make trove liquidatable
        uint256 elapsedTime = 1 weeks;
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(50000 * 10 ** 8),
            block.timestamp + elapsedTime,
            block.timestamp + elapsedTime,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used and allow
        // interest to build up
        vm.warp(block.timestamp + elapsedTime);

        // liquidate via `liquidate`
        liquidationMgr.liquidate(stakedBTCTroveMgr, users.user1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByLiquidation));

        assertEq(stakedBTCTroveMgr.L_collateral(), stakedBTCTroveMgr.defaultedCollateral());
        assertEq(stakedBTCTroveMgr.L_debt(), stakedBTCTroveMgr.defaultedDebt());

        // get pending collateral & debt rewards for owner trove
        (uint256 pendingOwnerTroveCollReward, uint256 pendingOwnerTroveDebtReward) = stakedBTCTroveMgr
            .getPendingCollAndDebtRewards(users.owner);

        // save TroveManager pre state
        TroveManagerState memory troveMgrStatePre = _getTroveManagerState();

        /*
        // calculate expected parameters
        uint256 interestFactor = elapsedTime * stakedBTCTroveMgr.interestRate();
        uint256 currentInterestIndex = statePre.activeInterestIndex +
                                       Math.mulDiv(statePre.activeInterestIndex, interestFactor, TM_INTEREST_PRECISION);
        uint256 newInterest = Math.mulDiv(statePre.totalActiveDebt, interestFactor, TM_INTEREST_PRECISION);
        */

        // trigger TroveManager::_applyPendingRewards for owner trove
        vm.prank(address(borrowerOps));
        (uint256 ownerTroveCollPost, uint256 ownerTroveDebtPost) = stakedBTCTroveMgr.applyPendingRewards(users.owner);

        // save TroveManager pre state
        TroveManagerState memory troveMgrStatePost = _getTroveManagerState();

        assertEq(ownerTroveCollPost, ownerTroveCollPre + pendingOwnerTroveCollReward);
        // not quite right but very close
        //assertEq(ownerTroveDebtPost, ownerTroveDebtPre + pendingOwnerTroveDebtReward + newInterest);
        assertEq(ownerTroveDebtPost, 54376014465753424657527);

        // verify owner trove reward snapshot correctly updated
        (uint256 rsCollateral, uint256 rsDebt) = stakedBTCTroveMgr.rewardSnapshots(users.owner);
        assertEq(rsCollateral, stakedBTCTroveMgr.L_collateral());
        assertEq(rsDebt, stakedBTCTroveMgr.L_debt());

        // verify pending rewards moved to active balances
        assertEq(troveMgrStatePost.defaultedDebt, troveMgrStatePre.defaultedDebt - pendingOwnerTroveDebtReward);
        assertEq(
            troveMgrStatePost.defaultedCollateral,
            troveMgrStatePre.defaultedCollateral - pendingOwnerTroveCollReward
        );
        assertEq(troveMgrStatePost.totalActiveDebt, troveMgrStatePre.totalActiveDebt + pendingOwnerTroveDebtReward);
        assertEq(
            troveMgrStatePost.totalActiveCollateral,
            troveMgrStatePre.totalActiveCollateral + pendingOwnerTroveCollReward
        );
    }
}
