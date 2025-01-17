// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// test setup
import {IBorrowerOperations, IIncentiveVoting, IFactory, SafeCast} from "../TestSetup.sol";

import {StabilityPoolTest} from "./StabilityPoolTest.t.sol";

import {BimaMath} from "../../../contracts/dependencies/BimaMath.sol";
import {BIMA_100_PCT} from "../../../contracts/dependencies/Constants.sol";
import {ITroveManager, IERC20} from "../../../contracts/interfaces/ITroveManager.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/console.sol";

// also tests TroveManager since BorrowerOps and TroveManager are very closely linked
contract BorrowerOperationsTest is StabilityPoolTest {
    ITroveManager internal stakedBTCTroveMgr;
    uint256 internal minCollateral;
    uint256 internal maxCollateral;
    uint256 internal minDebt;

    uint256 internal constant OWNER_TROVE_COLLATERAL = 1e18; // 1BTC

    // non-public copied from TroveManager.sol
    uint256 internal constant TM_INTEREST_PRECISION = 1e27;
    uint256 internal constant TM_SECONDS_IN_YEAR = 365 days;
    uint256 internal constant VOLUME_MULTIPLIER = 1e20;

    // since owner opens an initial trove, don't want to revert
    // during fuzz tests for trying to open more debt than allowed
    uint256 internal constant MAX_DEBT_AVAILABLE = INIT_MAX_DEBT - INIT_GAS_COMPENSATION * 2 - INIT_MIN_NET_DEBT;

    function setUp() public virtual override {
        super.setUp();

        // verify factory has deployed 1 TroveManager which has
        // StakedBTC as its collateral token
        assertEq(factory.troveManagerCount(), 1);
        stakedBTCTroveMgr = ITroveManager(factory.troveManagers(0));
        assertEq(address(stakedBTCTroveMgr.collateralToken()), address(stakedBTC));

        // verify StakedBTCTroveMgr has been registered with BorrowerOperations
        assertEq(borrowerOps.getTroveManagersCount(), 1);

        (IERC20 collateralToken, uint16 index) = borrowerOps.troveManagersData(stakedBTCTroveMgr);
        assertEq(address(collateralToken), address(stakedBTC));
        assertEq(index, 0);

        // owner always has one trove open with minimal debt
        // since liquidation doesn't work by design if only 1 trove
        _openTrove(users.owner, OWNER_TROVE_COLLATERAL, INIT_MIN_NET_DEBT);
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), 1);

        // verify view functions return correct data for owner trove
        assertEq(stakedBTCTroveMgr.getTroveStake(users.owner), OWNER_TROVE_COLLATERAL);

        (uint256 week, uint256 day) = stakedBTCTroveMgr.getWeekAndDay();
        uint32[7] memory mints = stakedBTCTroveMgr.getTotalMints(week);
        assertEq(mints[day], INIT_MIN_NET_DEBT / VOLUME_MULTIPLIER);

        assertEq(stakedBTCTroveMgr.getTroveFromTroveOwnersArray(0), users.owner);

        (uint256 coll, uint256 debt) = stakedBTCTroveMgr.getTroveCollAndDebt(users.owner);
        assertEq(coll, OWNER_TROVE_COLLATERAL);
        assertEq(debt, INIT_MIN_NET_DEBT + INIT_GAS_COMPENSATION);

        assertEq(stakedBTCTroveMgr.getEntireSystemColl(), OWNER_TROVE_COLLATERAL);

        assertFalse(stakedBTCTroveMgr.hasPendingRewards(users.owner));

        minCollateral = 3e17;
        maxCollateral = 1_000_000e18 - OWNER_TROVE_COLLATERAL;
        minDebt = INIT_MIN_NET_DEBT;
    }

    // used to store relevant state before tests for verification afterwards
    struct BorrowerOpsState {
        uint256 troveOwnersCount;
        uint256 userSBTCBal;
        uint256 userDebtTokenBal;
        uint256 gasPoolDebtTokenBal;
        uint256 troveMgrSBTCBal;
        IBorrowerOperations.SystemBalances sysBalances;
    }

    function _getBorrowerOpsState(address user) internal returns (BorrowerOpsState memory state) {
        state.troveOwnersCount = stakedBTCTroveMgr.getTroveOwnersCount();

        state.userSBTCBal = stakedBTC.balanceOf(user);
        state.userDebtTokenBal = debtToken.balanceOf(user);
        state.gasPoolDebtTokenBal = debtToken.balanceOf(users.gasPool);
        state.troveMgrSBTCBal = _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr));
        state.sysBalances = borrowerOps.fetchBalances();

        assertEq(state.sysBalances.collaterals.length, 1);
        assertEq(state.sysBalances.collaterals.length, state.sysBalances.debts.length);
        assertEq(state.sysBalances.collaterals.length, state.sysBalances.prices.length);
    }

    function _getMaxDebtAmount(uint256 collateralAmount) internal view returns (uint256 maxDebtAmount) {
        maxDebtAmount = BimaMath._min(
            MAX_DEBT_AVAILABLE,
            ((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) - INIT_GAS_COMPENSATION
        );
    }

    function _calcRedemptionFee(
        uint256 _redemptionRate,
        uint256 _collateralDrawn
    ) internal pure returns (uint256 redemptionFee) {
        redemptionFee = (_redemptionRate * _collateralDrawn) / 1e18;
        require(redemptionFee < _collateralDrawn, "Fee exceeds returned collateral");
    }

    // helper function to open a trove
    function _openTrove(address user, uint256 collateralAmount, uint256 debtAmount) internal {
        _sendStakedBtc(user, collateralAmount);

        // save previous state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(user);

        vm.prank(user);
        stakedBTC.approve(address(borrowerOps), collateralAmount);

        vm.prank(user);
        borrowerOps.openTrove(
            stakedBTCTroveMgr,
            user,
            0, // maxFeePercentage
            collateralAmount,
            debtAmount,
            address(0),
            address(0)
        ); // hints

        // verify trove owners count increased
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), statePre.troveOwnersCount + 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(user)), uint8(ITroveManager.Status.active));

        // verify borrower received debt tokens
        assertEq(debtToken.balanceOf(user), statePre.userDebtTokenBal + debtAmount);

        // verify gas pool received gas compensation tokens
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal + INIT_GAS_COMPENSATION);

        // verify TroveManager received collateral tokens
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal + collateralAmount
        );

        // verify system balances
        IBorrowerOperations.SystemBalances memory balances = borrowerOps.fetchBalances();
        assertEq(balances.collaterals.length, 1);
        assertEq(balances.collaterals.length, balances.debts.length);
        assertEq(balances.collaterals.length, balances.prices.length);

        assertEq(balances.collaterals[0], statePre.sysBalances.collaterals[0] + collateralAmount);
        assertEq(balances.debts[0], statePre.sysBalances.debts[0] + debtAmount + INIT_GAS_COMPENSATION);
        assertEq(balances.prices[0], statePre.sysBalances.prices[0]);
    }

    function _openTroveThenRecoveryMode() internal returns (uint256 collateralAmount, uint256 debtAmountMax) {
        // user1 opens a trove using 20 BTC collateral (price = $60,000 in MockOracle)
        collateralAmount = 20e18;
        debtAmountMax = _getMaxDebtAmount(collateralAmount);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        uint256 userICR = stakedBTCTroveMgr.getCurrentICR(users.user1, stakedBTCTroveMgr.fetchPrice());
        assertEq(userICR, 2250000000000000000);

        // set new value of btc to $53,335 to make trove liquidatable
        // with ICR >= MCR and TCR < CCR and ICR < TCR which triggers
        // recovery mode
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(53335 * 10 ** 8),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        uint256 TCR = borrowerOps.getTCR();
        assertTrue(borrowerOps.checkRecoveryMode(TCR));
    }

    function test_openTrove_failInvalidTroveManager() external {
        vm.expectRevert("Collateral not enabled");
        vm.prank(users.user1);
        borrowerOps.openTrove(troveMgr, users.user1, 1e18, 1e18, 0, address(0), address(0));
    }

    function test_openTrove(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) public returns (uint256 actualCollateralAmount, uint256 actualDebtAmount) {
        // bound fuzz inputs
        actualCollateralAmount = bound(collateralAmount, minCollateral, maxCollateral);
        btcPrice = bound(btcPrice, MIN_BTC_PRICE_8DEC, MAX_BTC_PRICE_8DEC);

        // set new btc price with mock oracle
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(btcPrice),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );
        // warp time to prevent cached price being used
        vm.warp(block.timestamp + 1);

        // get max debt possible for random collateral amount and random btc price
        uint256 debtAmountMax = _getMaxDebtAmount(actualCollateralAmount);

        // get random debt between min and max possible for random collateral amount
        actualDebtAmount = bound(debtAmount, minDebt, debtAmountMax);

        _openTrove(users.user1, actualCollateralAmount, actualDebtAmount);
    }

    function test_openTrove_custom() external {
        // depositing 2 BTC collateral (price = $60,000 in MockOracle)
        // use this test to experiment with different hard-coded values
        uint256 collateralAmount = 2e18;

        uint256 debtAmountMax = ((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION;

        _openTrove(users.user1, collateralAmount, debtAmountMax);
    }

    function test_openTrove_usingDelegatedAccount() external {
        // depositing 2 BTC collateral (price = $60,000 in MockOracle)
        // use this test to experiment with different hard-coded values
        uint256 collateralAmount = 2e18;

        uint256 debtAmountMax = ((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION;

        // user1 delegates to user2
        vm.prank(users.user1);
        borrowerOps.setDelegateApproval(users.user2, true);

        _sendStakedBtc(users.user2, collateralAmount);

        // save previous state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        vm.prank(users.user2);
        stakedBTC.approve(address(borrowerOps), collateralAmount);

        // user2 does the call as user1's delegate
        vm.prank(users.user2);
        borrowerOps.openTrove(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            collateralAmount,
            debtAmountMax,
            address(0),
            address(0)
        ); // hints

        // verify trove owners count increased
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), statePre.troveOwnersCount + 1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower received debt tokens at delegatee address
        assertEq(debtToken.balanceOf(users.user2), statePre.userDebtTokenBal + debtAmountMax);

        // verify gas pool received gas compensation tokens
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal + INIT_GAS_COMPENSATION);

        // verify TroveManager received collateral tokens
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal + collateralAmount
        );

        // verify system balances
        IBorrowerOperations.SystemBalances memory balances = borrowerOps.fetchBalances();
        assertEq(balances.collaterals.length, 1);
        assertEq(balances.collaterals.length, balances.debts.length);
        assertEq(balances.collaterals.length, balances.prices.length);

        assertEq(balances.collaterals[0], statePre.sysBalances.collaterals[0] + collateralAmount);
        assertEq(balances.debts[0], statePre.sysBalances.debts[0] + debtAmountMax + INIT_GAS_COMPENSATION);
        assertEq(balances.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_openTrove_inRecoveryMode() external {
        (uint256 collateralAmount, uint256 debtAmountMax) = _openTroveThenRecoveryMode();

        // if user2 attempts to open a trove with ICR < CCR, this fails
        vm.expectRevert("BorrowerOps: Operation must leave trove with ICR >= CCR");
        vm.prank(users.user2);
        borrowerOps.openTrove(
            stakedBTCTroveMgr,
            users.user2,
            0, // maxFeePercentage
            collateralAmount,
            debtAmountMax,
            address(0),
            address(0)
        ); // hints

        // user2 can open a trove with ICR >= CCR
        _sendStakedBtc(users.user2, collateralAmount);
        vm.prank(users.user2);
        stakedBTC.approve(address(borrowerOps), collateralAmount);
        vm.prank(users.user2);
        borrowerOps.openTrove(
            stakedBTCTroveMgr,
            users.user2,
            0, // maxFeePercentage
            collateralAmount,
            debtAmountMax / 2,
            address(0),
            address(0)
        ); // hints

        assertTrue(stakedBTCTroveMgr.getCurrentICR(users.user2, stakedBTCTroveMgr.fetchPrice()) > borrowerOps.CCR());
    }

    function test_addColl(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) public returns (uint256 addedCollateral) {
        // first limit the max collateral to ensure enough tokens remain
        maxCollateral /= 2;

        // bound fuzz inputs
        addedCollateral = bound(collateralAmount, 1, maxCollateral);

        // then open a new trove
        test_openTrove(collateralAmount, debtAmount, btcPrice);

        // give user extra staked btc collateral
        _sendStakedBtc(users.user1, addedCollateral);

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // transfer approval
        vm.prank(users.user1);
        stakedBTC.approve(address(borrowerOps), addedCollateral);

        // add the new collateral to the existing trove
        vm.prank(users.user1);
        borrowerOps.addColl(stakedBTCTroveMgr, users.user1, addedCollateral, address(0), address(0)); // hints

        // verify trove status unchanged
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower debt tokens unchanged
        assertEq(debtToken.balanceOf(users.user1), statePre.userDebtTokenBal);

        // verify gas pool gas compensation tokens unchanged
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal);

        // verify TroveManager received additional collateral tokens
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal + addedCollateral
        );

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0] + addedCollateral);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0]);
        assertEq(sysBalancesPost.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_withdrawColl(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) external returns (uint256 withdrawnCollateral) {
        // first open a trove and add some extra collateral
        uint256 addedCollateral = test_addColl(collateralAmount, debtAmount, btcPrice);

        // bound fuzz inputs
        withdrawnCollateral = bound(addedCollateral, 1, addedCollateral);

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // withdraw the extra collateral
        vm.prank(users.user1);
        borrowerOps.withdrawColl(stakedBTCTroveMgr, users.user1, withdrawnCollateral, address(0), address(0)); // hints

        // verify trove status unchanged
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower debt tokens unchanged
        assertEq(debtToken.balanceOf(users.user1), statePre.userDebtTokenBal);

        // verify gas pool compensation tokens unchanged
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal);

        // verify TroveManager sent withdrawn collateral tokens
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal - withdrawnCollateral
        );

        // verify user received withdrawn collateral tokens
        assertEq(stakedBTC.balanceOf(users.user1), statePre.userSBTCBal + withdrawnCollateral);

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0] - withdrawnCollateral);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0]);
        assertEq(sysBalancesPost.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_withdrawColl_failsInRecoveryMode() external {
        (uint256 collateralAmount /*uint256 debtAmountMax*/, ) = _openTroveThenRecoveryMode();

        vm.expectRevert("BorrowerOps: Collateral withdrawal not permitted Recovery Mode");
        vm.prank(users.user1);
        borrowerOps.withdrawColl(stakedBTCTroveMgr, users.user1, collateralAmount, address(0), address(0)); // hints
    }

    function test_withdrawDebt(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) external returns (uint256 withdrawnDebt) {
        // first limit the max collateral to prevent max debt being taken
        // when opening a trove
        maxCollateral = 4e18;

        // then open a trove and add some extra collateral
        uint256 addedCollateral = test_addColl(collateralAmount, debtAmount, btcPrice);

        // get max debt possible for extra collateral amount
        uint256 debtAmountMax = (addedCollateral * _getScaledOraclePrice()) / borrowerOps.CCR();

        // get random debt between min and max possible for extra collateral amount
        withdrawnDebt = bound(debtAmount, 1, debtAmountMax);

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // withdraw the debt
        vm.prank(users.user1);
        borrowerOps.withdrawDebt(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            withdrawnDebt,
            address(0),
            address(0)
        ); // hints

        // verify trove status unchanged
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower received withdrawn debt tokens
        assertEq(debtToken.balanceOf(users.user1), statePre.userDebtTokenBal + withdrawnDebt);

        // verify gas pool compensation tokens unchanged
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal);

        // verify TroveManager collateral tokens unchanged
        assertEq(_wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)), statePre.troveMgrSBTCBal);

        // verify user collateral tokens unchanged
        assertEq(stakedBTC.balanceOf(users.user1), statePre.userSBTCBal);

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0]);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0] + withdrawnDebt);
        assertEq(sysBalancesPost.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_withdrawDebt_inRecoveryMode() external {
        (uint256 collateralAmount, uint256 debtAmountMax) = _openTroveThenRecoveryMode();

        vm.expectRevert("BorrowerOps: Operation must leave trove with ICR >= CCR");
        vm.prank(users.user1);
        borrowerOps.withdrawDebt(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            1,
            address(0),
            address(0)
        ); // hints

        uint256 newCollateralDepositAmount = collateralAmount / 2;

        // give user extra staked btc collateral
        _sendStakedBtc(users.user1, newCollateralDepositAmount);

        // transfer approval
        vm.prank(users.user1);
        stakedBTC.approve(address(borrowerOps), newCollateralDepositAmount);

        // add the new collateral to the existing trove
        vm.prank(users.user1);
        borrowerOps.addColl(stakedBTCTroveMgr, users.user1, newCollateralDepositAmount, address(0), address(0)); // hints

        vm.expectRevert("BorrowerOps: An operation that would result in TCR < CCR is not permitted");
        vm.prank(users.user1);
        borrowerOps.withdrawDebt(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            debtAmountMax / 2,
            address(0),
            address(0)
        ); // hints

        vm.prank(users.user1);
        borrowerOps.withdrawDebt(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            debtAmountMax / 4,
            address(0),
            address(0)
        ); // hints
    }

    function test_closeTrove(uint256 collateralAmount, uint256 debtAmount, uint256 btcPrice) external {
        // first open a new trove
        (uint256 actualCollateralAmount, uint256 actualDebtAmount) = test_openTrove(
            collateralAmount,
            debtAmount,
            btcPrice
        );

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // then close it
        vm.prank(users.user1);
        borrowerOps.closeTrove(stakedBTCTroveMgr, users.user1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByOwner));

        // verify trove owners count decreased
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), statePre.troveOwnersCount - 1);

        // verify borrower has zero debt tokens
        assertEq(debtToken.balanceOf(users.user1), 0);

        // verify gas pool compensation tokens reduced
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal - INIT_GAS_COMPENSATION);

        // verify TroveManager collateral tokens reduced by closed trove
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal - actualCollateralAmount
        );

        // verify user received collateral tokens
        assertEq(stakedBTC.balanceOf(users.user1), statePre.userSBTCBal + actualCollateralAmount);

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0] - actualCollateralAmount);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0] - actualDebtAmount - INIT_GAS_COMPENSATION);
        assertEq(sysBalancesPost.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_repayDebt(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) external returns (uint256 repayAmount) {
        // increase the minimum debt to ensure repay won't revert
        // due to going below the minimum debt value
        minDebt = (INIT_MIN_NET_DEBT * 130) / 100;

        // open a new trove
        (, uint256 actualDebtAmount) = test_openTrove(collateralAmount, debtAmount, btcPrice);

        // bound repay amount to prevent revert due to going below
        // mininum debt value
        repayAmount = bound(actualDebtAmount, 1, actualDebtAmount - INIT_MIN_NET_DEBT);

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // repay some debt
        vm.prank(users.user1);
        borrowerOps.repayDebt(stakedBTCTroveMgr, users.user1, repayAmount, address(0), address(0));

        // verify trove status unchanged
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower has reduced debt tokens
        assertEq(debtToken.balanceOf(users.user1), actualDebtAmount - repayAmount);

        // verify gas pool compensation debt tokens unchanged
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal);

        // verify TroveManager has collateral tokens unchanged
        assertEq(_wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)), statePre.troveMgrSBTCBal);

        // verify user collateral tokens unchanged
        assertEq(stakedBTC.balanceOf(users.user1), statePre.userSBTCBal);

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0]);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0] - repayAmount);
        assertEq(sysBalancesPost.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_removeTroveManager() external {
        vm.expectRevert("Trove Manager cannot be removed");
        borrowerOps.removeTroveManager(stakedBTCTroveMgr);

        // sunset the trove manager
        vm.prank(users.owner);
        stakedBTCTroveMgr.startSunset();
        assertTrue(stakedBTCTroveMgr.sunsetting());

        // still can't remove as one open trove remains
        vm.expectRevert("Trove Manager cannot be removed");
        borrowerOps.removeTroveManager(stakedBTCTroveMgr);

        deal(address(stakedBTC), users.user1, 1e18, true);
        vm.prank(users.user1);
        stakedBTC.approve(address(borrowerOps), 1e18);

        // verify new trove can't be opened while sunsetting
        vm.expectRevert("Cannot open while sunsetting");
        vm.prank(users.user1);
        borrowerOps.openTrove(
            stakedBTCTroveMgr,
            users.user1,
            0, // maxFeePercentage
            1e18,
            INIT_MIN_NET_DEBT,
            address(0),
            address(0)
        ); // hints

        // close the owner's trove
        vm.prank(users.owner);
        borrowerOps.closeTrove(stakedBTCTroveMgr, users.owner);
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), 0);

        // now can finally remove the trove manager
        borrowerOps.removeTroveManager(stakedBTCTroveMgr);
        assertEq(borrowerOps.getTroveManagersCount(), 0);

        (IERC20 collateralToken, uint16 index) = borrowerOps.troveManagersData(stakedBTCTroveMgr);
        assertEq(address(collateralToken), address(0));
        assertEq(index, 0);
    }

    function test_removeTroveManager_withMultipleTroveManagers() external {
        // sunset the trove manager
        vm.prank(users.owner);
        stakedBTCTroveMgr.startSunset();
        assertTrue(stakedBTCTroveMgr.sunsetting());

        // close the owner's trove
        vm.prank(users.owner);
        borrowerOps.closeTrove(stakedBTCTroveMgr, users.owner);
        assertEq(stakedBTCTroveMgr.getTroveOwnersCount(), 0);

        // add 2 additional trove managers to exercise the
        // swap & pop removal code
        IERC20 coll2 = IERC20(address(0x1234));
        IERC20 coll3 = IERC20(address(0x12345));

        // deploy 2 new trove managers
        ITroveManager tv2 = ITroveManager(address(0x9876));
        ITroveManager tv3 = ITroveManager(address(0x9875));

        vm.prank(address(factory));
        borrowerOps.configureCollateral(tv2, coll2);
        vm.prank(address(factory));
        borrowerOps.configureCollateral(tv3, coll3);

        // 3 TroveManagers deployed
        assertEq(borrowerOps.getTroveManagersCount(), 3);

        // now can finally remove the trove manager
        borrowerOps.removeTroveManager(stakedBTCTroveMgr);
        assertEq(borrowerOps.getTroveManagersCount(), 2);

        (IERC20 collateralToken, uint16 index) = borrowerOps.troveManagersData(stakedBTCTroveMgr);
        assertEq(address(collateralToken), address(0));
        assertEq(index, 0);

        // previously last trove manager should now be first
        (collateralToken, index) = borrowerOps.troveManagersData(tv3);
        assertEq(address(collateralToken), address(coll3));
        assertEq(index, 0);

        // previously second trove manager should now be last
        (collateralToken, index) = borrowerOps.troveManagersData(tv2);
        assertEq(address(collateralToken), address(coll2));
        assertEq(index, 1);
    }

    function test_redeemCollateral_whileSunsetting(
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 btcPrice
    ) external {
        // owner closes their trove to simplify things
        vm.prank(users.owner);
        borrowerOps.closeTrove(stakedBTCTroveMgr, users.owner);

        // fast forward time to after bootstrap period
        vm.warp(stakedBTCTroveMgr.systemDeploymentTime() + stakedBTCTroveMgr.BOOTSTRAP_PERIOD());

        // user1 opens a new trove
        (uint256 actualCollateralAmount, uint256 actualDebtAmount) = test_openTrove(
            collateralAmount,
            debtAmount,
            btcPrice
        );

        // sunset the trove manager
        vm.prank(users.owner);
        stakedBTCTroveMgr.startSunset();
        assertTrue(stakedBTCTroveMgr.sunsetting());

        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        // redeem the trove; note : suboptimal to redeem your own trove, much
        // better to use closeTrove - just doing it to simplify the fuzz test
        vm.prank(users.user1);
        stakedBTCTroveMgr.redeemCollateral(actualDebtAmount, address(0), address(0), address(0), 0, 0, 0);

        // user1 claims the remaining collateral put into surplusBalances
        vm.prank(users.user1);
        stakedBTCTroveMgr.claimCollateral(users.user1);

        // save post state
        BorrowerOpsState memory statePost = _getBorrowerOpsState(users.user1);

        // verify correct trove status
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByRedemption));

        // verify trove owners count decreased
        assertEq(statePost.troveOwnersCount, statePre.troveOwnersCount - 1);

        // verify borrower has zero debt tokens
        assertEq(statePost.userDebtTokenBal, 0);

        // verify borrower received back all collateral tokens
        // since no redemption fee when TroveManager is sunsetting
        assertEq(statePost.userSBTCBal, actualCollateralAmount);

        // verify gas pool compensation tokens reduced
        assertEq(statePost.gasPoolDebtTokenBal, statePre.gasPoolDebtTokenBal - INIT_GAS_COMPENSATION);

        // verify no remaining collateral or debt
        assertEq(statePost.sysBalances.collaterals[0], 0);
        assertEq(statePost.sysBalances.debts[0], 0);
        assertEq(statePost.sysBalances.prices[0], statePre.sysBalances.prices[0]);
    }

    function test_redeemCollateral_fixForNoCollateralForRemainingAmount() external {
        // fast forward time to after bootstrap period
        vm.warp(stakedBTCTroveMgr.systemDeploymentTime() + stakedBTCTroveMgr.BOOTSTRAP_PERIOD());

        // update price oracle response to prevent stale revert
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            mockOracle.answer(),
            mockOracle.startedAt(),
            block.timestamp,
            mockOracle.answeredInRound() + 1
        );

        // user1 opens a trove with 1 BTC collateral for their max borrowing power
        uint256 collateralAmount = 1e18;

        uint256 debtAmountMax = (((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // user2 opens a trove with 1 BTC collateral for their max borrowing power
        _openTrove(users.user2, collateralAmount, debtAmountMax);

        // mint user3 enough debt tokens such that they will close
        // user1's trove and attempt to redeem part of user2's trove,
        // but the second amount is small enough to trigger a rounding
        // down to zero precision loss in the `singleRedemption.collateralLot`
        // calculation
        uint256 excessDebtTokens = 59_999;
        uint256 debtToSend = debtAmountMax + excessDebtTokens;

        vm.prank(address(borrowerOps));
        debtToken.mint(users.user3, debtToSend);
        assertEq(debtToken.balanceOf(users.user3), debtToSend);
        assertEq(stakedBTC.balanceOf(users.user3), 0);

        // save system balances prior to redemption
        IBorrowerOperations.SystemBalances memory balancesPre = borrowerOps.fetchBalances();
        assertEq(balancesPre.collaterals.length, 1);
        assertEq(balancesPre.collaterals.length, balancesPre.debts.length);
        assertEq(balancesPre.collaterals.length, balancesPre.prices.length);

        // user3 exchanges their debt tokens for collateral
        uint256 maxFeePercent = stakedBTCTroveMgr.maxRedemptionFee();

        vm.prank(users.user3);
        stakedBTCTroveMgr.redeemCollateral(
            debtToSend,
            users.user1,
            address(0),
            address(0),
            3750000000000000,
            0,
            maxFeePercent
        );

        // verify user3 has "excess" remaining tokens as the second vault
        // return early with cancelledPartial = true due to detecting
        // rounding down to zero in collateralLot calculation
        assertEq(debtToken.balanceOf(users.user3), excessDebtTokens);

        // verify user3 received some collateral tokens
        uint256 user3ReceivedCollateral = stakedBTC.balanceOf(users.user3);
        assertEq(user3ReceivedCollateral, 333149704522991056);

        // verify user1's trove was closed by the redemption
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByRedemption));

        // verify user2's trove remains active
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user2)), uint8(ITroveManager.Status.active));

        // user1 claims the remaining collateral
        vm.prank(users.user1);
        stakedBTCTroveMgr.claimCollateral(users.user1);

        // get user1 state
        BorrowerOpsState memory statePost = _getBorrowerOpsState(users.user1);

        // verify trove count decreased by 1
        assertEq(statePost.troveOwnersCount, 2);

        // calculate redemption fee
        uint256 redemptionFee = _calcRedemptionFee(stakedBTCTroveMgr.getRedemptionRate(), 444427777777777777);

        // verify user1 received correct remaining collateral
        assertEq(statePost.userSBTCBal, collateralAmount - user3ReceivedCollateral - redemptionFee);
        // verify user1 has their original debt tokens since user3's debt tokens
        // were used to close the trove
        assertEq(statePost.userDebtTokenBal, debtAmountMax);

        // get user2 state
        statePost = _getBorrowerOpsState(users.user2);

        // verify user2 state unchanged
        assertEq(statePost.userSBTCBal, collateralAmount - INIT_GAS_COMPENSATION);
        assertEq(statePost.userDebtTokenBal, debtAmountMax);

        // verify remaining collateral & debt is owner + user2
        assertEq(statePost.sysBalances.collaterals[0], OWNER_TROVE_COLLATERAL + collateralAmount);
        assertEq(statePost.sysBalances.debts[0], INIT_MIN_NET_DEBT + debtAmountMax + INIT_GAS_COMPENSATION * 2);
        assertEq(statePost.sysBalances.prices[0], balancesPre.prices[0]);
    }

    function test_redeemCollateral_closeOneTrovePartialRedeemOther() external {
        // fast forward time to after bootstrap period
        vm.warp(stakedBTCTroveMgr.systemDeploymentTime() + stakedBTCTroveMgr.BOOTSTRAP_PERIOD());

        // update price oracle response to prevent stale revert
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            mockOracle.answer(),
            mockOracle.startedAt(),
            block.timestamp,
            mockOracle.answeredInRound() + 1
        );

        // user1 opens a trove with 5 BTC collateral for their max borrowing power
        uint256 collateralAmount = 5e18;

        uint256 debtAmountMax = (((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // user2 opens a trove with 1 BTC collateral for their max borrowing power
        _openTrove(users.user2, collateralAmount, debtAmountMax);

        // mint user3 enough debt tokens such that 1 trove will be closed
        // and a partial redemption will occur from another trove
        uint256 debtToSend = debtAmountMax + debtAmountMax / 2;

        vm.prank(address(borrowerOps));
        debtToken.mint(users.user3, debtToSend);
        assertEq(debtToken.balanceOf(users.user3), debtToSend);
        assertEq(stakedBTC.balanceOf(users.user3), 0);

        // save system balances prior to redemption
        IBorrowerOperations.SystemBalances memory balancesPre = borrowerOps.fetchBalances();
        assertEq(balancesPre.collaterals.length, 1);
        assertEq(balancesPre.collaterals.length, balancesPre.debts.length);
        assertEq(balancesPre.collaterals.length, balancesPre.prices.length);

        // user3 exchanges their debt tokens for collateral
        uint256 maxFeePercent = stakedBTCTroveMgr.maxRedemptionFee();

        vm.prank(users.user3);
        stakedBTCTroveMgr.redeemCollateral(
            debtToSend,
            users.user1,
            address(0),
            address(0),
            5833302083567706,
            0,
            maxFeePercent
        );

        // verify user3 has no debt tokens remaining
        assertEq(debtToken.balanceOf(users.user3), 0);

        // verify user3 received some collateral tokens
        uint256 user3ReceivedCollateral = stakedBTC.balanceOf(users.user3);
        assertEq(user3ReceivedCollateral, 2071335111546853914);

        // verify user1's trove was closed by the redemption
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.closedByRedemption));

        // verify user2's trove is still active
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user2)), uint8(ITroveManager.Status.active));

        // user1 claims the remaining collateral
        vm.prank(users.user1);
        stakedBTCTroveMgr.claimCollateral(users.user1);

        // get user1 state
        BorrowerOpsState memory statePost = _getBorrowerOpsState(users.user1);

        // verify trove count decreased by 1
        assertEq(statePost.troveOwnersCount, 2);

        // verify user1 received correct remaining collateral
        assertEq(statePost.userSBTCBal, 2777794444444444445);

        // verify user1 has their original debt tokens since user3's debt tokens
        // were used to close the trove
        assertEq(statePost.userDebtTokenBal, debtAmountMax);

        // get user2 state
        statePost = _getBorrowerOpsState(users.user2);

        // verify user2 has no collateral as their trove was not closed
        assertEq(statePost.userSBTCBal, 0);
        // verify user2 debt unchanged
        assertEq(statePost.userDebtTokenBal, debtAmountMax);

        // user2 open trove has its collateral reduced
        (uint256 coll, uint256 debt) = stakedBTCTroveMgr.getTroveCollAndDebt(users.user2);
        assertEq(coll, 3888897222222222223);
        // and its debt was approximately halved
        assertEq(debt, 66667166666666666666667);
    }

    function test_claimReward_someTroveManagerDebtRewardsLost() external {
        // setup vault giving user1 half supply to lock for voting power
        uint256 initialUnallocated = _vaultSetupAndLockTokens(INIT_BAB_TKN_TOTAL_SUPPLY / 2, true);

        // owner registers TroveManager for vault emission rewards
        vm.prank(users.owner);
        bimaVault.registerReceiver(address(stakedBTCTroveMgr), 2);

        // user votes for TroveManager debtId to get emissions
        (uint16 TM_RECEIVER_DEBT_ID /*uint16 TM_RECEIVER_MINT_ID*/, ) = stakedBTCTroveMgr.emissionId();

        IIncentiveVoting.Vote[] memory votes = new IIncentiveVoting.Vote[](1);
        votes[0].id = TM_RECEIVER_DEBT_ID;
        votes[0].points = incentiveVoting.MAX_POINTS();

        vm.prank(users.user1);
        incentiveVoting.registerAccountWeightAndVote(users.user1, 52, votes);

        // user1 and user2 open a trove with 1 BTC collateral for their max borrowing power
        uint256 collateralAmount = 1e18;
        uint256 debtAmountMax = (((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION);

        _openTrove(users.user1, collateralAmount, debtAmountMax);
        _openTrove(users.user2, collateralAmount, debtAmountMax);

        // warp time by 1 week
        vm.warp(block.timestamp + 1 weeks);

        // calculate expected first week emissions
        uint256 firstWeekEmissions = (initialUnallocated * INIT_ES_WEEKLY_PCT) / BIMA_100_PCT;
        assertEq(firstWeekEmissions, 536870911875000000000000000);
        assertEq(bimaVault.unallocatedTotal(), initialUnallocated);

        uint16 systemWeek = SafeCast.toUint16(bimaVault.getWeek());

        // no rewards in the same week as emissions
        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), 0);
        assertEq(stakedBTCTroveMgr.claimableReward(users.user2), 0);

        vm.prank(users.user1);
        uint256 userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, 0);
        vm.prank(users.user2);
        userReward = stakedBTCTroveMgr.claimReward(users.user2);
        assertEq(userReward, 0);

        // verify emissions correctly set in BimaVault for first week
        assertEq(bimaVault.weeklyEmissions(systemWeek), firstWeekEmissions);

        // warp time by 1 week
        vm.warp(block.timestamp + 1 weeks);

        // rewards for the first week can be claimed now
        // users receive less?
        assertEq(firstWeekEmissions / 2, 268435455937500000000000000);
        uint256 actualUserReward = 263490076563008042796633412;

        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), actualUserReward);
        assertEq(stakedBTCTroveMgr.claimableReward(users.user2), actualUserReward);

        // verify user1 rewards
        vm.prank(users.user1);
        userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, actualUserReward);

        // verify user2 rewards
        vm.prank(users.user2);
        userReward = stakedBTCTroveMgr.claimReward(users.user2);
        assertEq(userReward, actualUserReward);

        // firstWeekEmissions = 536870911875000000000000000
        // userReward * 2     = 526980153126016085593266824
        //
        // some rewards were not distributed and are effectively lost

        // if either users tries to claim again, nothing is returned
        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), 0);
        assertEq(stakedBTCTroveMgr.claimableReward(users.user2), 0);

        vm.prank(users.user1);
        userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, 0);
        vm.prank(users.user2);
        userReward = stakedBTCTroveMgr.claimReward(users.user2);
        assertEq(userReward, 0);

        // refresh mock oracle to prevent frozen feed revert
        mockOracle.refresh();

        // user2 closes their trove
        vm.prank(users.user2);
        borrowerOps.closeTrove(stakedBTCTroveMgr, users.user2);

        uint256 secondWeekEmissions = ((initialUnallocated - firstWeekEmissions) * INIT_ES_WEEKLY_PCT) / BIMA_100_PCT;
        assertEq(secondWeekEmissions, 402653183906250000000000000);
        assertEq(bimaVault.weeklyEmissions(systemWeek + 1), secondWeekEmissions);

        // warp time by 1 week
        vm.warp(block.timestamp + 1 weeks);

        // user2 can't claim anything as they withdrew
        assertEq(stakedBTCTroveMgr.claimableReward(users.user2), 0);
        vm.prank(users.user2);
        userReward = stakedBTCTroveMgr.claimReward(users.user2);
        assertEq(userReward, 0);

        // user1 gets almost all the weekly emissions apart
        // from an amount that is lost
        actualUserReward = 388085427183354818500070297;
        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), actualUserReward);

        vm.prank(users.user1);
        userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, actualUserReward);

        // weekly emissions 402653183906250000000000000
        // user1 received   388085427183354818500070297

        // user1 can't claim more rewards
        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), 0);
        vm.prank(users.user1);
        userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, 0);
    }

    function test_claimReward_troveManagerMintRewards() external {
        // setup vault giving user1 half supply to lock for voting power
        uint256 initialUnallocated = _vaultSetupAndLockTokens(INIT_BAB_TKN_TOTAL_SUPPLY / 2, true);

        // owner registers TroveManager for vault emission rewards
        vm.prank(users.owner);
        bimaVault.registerReceiver(address(stakedBTCTroveMgr), 2);

        // user votes for TroveManager debtId to get emissions
        (, /*uint16 TM_RECEIVER_DEBT_ID*/ uint16 TM_RECEIVER_MINT_ID) = stakedBTCTroveMgr.emissionId();

        IIncentiveVoting.Vote[] memory votes = new IIncentiveVoting.Vote[](1);
        votes[0].id = TM_RECEIVER_MINT_ID;
        votes[0].points = incentiveVoting.MAX_POINTS();

        vm.prank(users.user1);
        incentiveVoting.registerAccountWeightAndVote(users.user1, 52, votes);

        // user1 and user2 open a trove with 1 BTC collateral for their max borrowing power
        uint256 collateralAmount = 1e18;
        uint256 debtAmountMax = (((collateralAmount * _getScaledOraclePrice()) / borrowerOps.CCR()) -
            INIT_GAS_COMPENSATION);

        _openTrove(users.user1, collateralAmount, debtAmountMax);

        // warp time by 1 week
        vm.warp(block.timestamp + 1 weeks);

        // refresh mock oracle to prevent frozen feed revert
        mockOracle.refresh();

        _openTrove(users.user2, collateralAmount, debtAmountMax);

        // calculate expected first week emissions
        uint256 firstWeekEmissions = (initialUnallocated * INIT_ES_WEEKLY_PCT) / BIMA_100_PCT;
        uint16 systemWeek = SafeCast.toUint16(bimaVault.getWeek());

        // no rewards in the same week as emissions
        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), 0);
        assertEq(stakedBTCTroveMgr.claimableReward(users.user2), 0);

        // user1 claims which updates total weekly emissions
        vm.prank(users.user1);
        stakedBTCTroveMgr.claimReward(users.user1);

        // verify emissions correctly set in BimaVault for first week
        assertEq(bimaVault.weeklyEmissions(systemWeek), firstWeekEmissions);

        // warp time by 1 week
        vm.warp(block.timestamp + 1 weeks);

        (uint256 week, uint256 day) = stakedBTCTroveMgr.getWeekAndDay();
        assertEq(week, systemWeek + 1);

        assertGt(stakedBTCTroveMgr.getTotalMints(systemWeek - 1)[day], 0); // user1's mint
        assertGt(stakedBTCTroveMgr.getTotalMints(systemWeek)[day], 0); // user2's mint

        assertEq(stakedBTCTroveMgr.dailyMintReward(systemWeek - 1), 0);
        assertGt(stakedBTCTroveMgr.dailyMintReward(systemWeek), 0); // >0 from user1's mint at systemWeek-1

        assertEq(stakedBTCTroveMgr.claimableReward(users.user1), 0); // no rewards
        assertGt(stakedBTCTroveMgr.claimableReward(users.user2), 0); // rewards

        // no rewards for user1
        vm.prank(users.user1);
        uint256 userReward = stakedBTCTroveMgr.claimReward(users.user1);
        assertEq(userReward, 0);

        // rewards for user2
        vm.prank(users.user2);
        userReward = stakedBTCTroveMgr.claimReward(users.user2);
        assertGt(userReward, 0);
    }

    function test_setMinNetDebt_failsNotOwner() external {
        vm.expectRevert("Only owner");
        borrowerOps.setMinNetDebt(1);
    }

    function test_setMinNetDebt() external {
        uint256 newMinNetDebt = 1;
        vm.prank(users.owner);
        borrowerOps.setMinNetDebt(newMinNetDebt);

        assertEq(borrowerOps.minNetDebt(), newMinNetDebt);
    }

    function test_getCompositeDebt(uint256 debt) external view {
        debt = bound(debt, 0, type(uint256).max - borrowerOps.DEBT_GAS_COMPENSATION());

        uint256 compositeDebt = borrowerOps.getCompositeDebt(debt);
        assertEq(compositeDebt, debt + borrowerOps.DEBT_GAS_COMPENSATION());
    }

    function test_setPaused_guardianCanPauseNotUnpause() external {
        vm.prank(users.guardian);
        stakedBTCTroveMgr.setPaused(true);

        assertTrue(stakedBTCTroveMgr.paused());

        vm.expectRevert("Unauthorized");
        vm.prank(users.guardian);
        stakedBTCTroveMgr.setPaused(false);
    }

    function test_setPaused_ownerCanPauseUnpause() external {
        vm.prank(users.owner);
        stakedBTCTroveMgr.setPaused(true);

        assertTrue(stakedBTCTroveMgr.paused());

        vm.prank(users.owner);
        stakedBTCTroveMgr.setPaused(false);

        assertFalse(stakedBTCTroveMgr.paused());
    }

    function test_setPaused_failNormalUser() external {
        vm.expectRevert("Unauthorized");
        vm.prank(users.user1);
        stakedBTCTroveMgr.setPaused(true);

        vm.expectRevert("Unauthorized");
        vm.prank(users.user1);
        stakedBTCTroveMgr.setPaused(false);
    }

    function test_setPriceFeed_failNotOwner() external {
        vm.expectRevert("Only owner");
        stakedBTCTroveMgr.setPriceFeed(address(0x1234));
    }

    function test_setPriceFeed() external {
        vm.prank(users.owner);
        stakedBTCTroveMgr.setPriceFeed(address(0x1234));

        assertEq(address(stakedBTCTroveMgr.priceFeed()), address(0x1234));
    }

    function test_setParameters_failNotOwner() external {
        IFactory.DeploymentParams memory params = IFactory.DeploymentParams({
            minuteDecayFactor: 999037758833783000,
            redemptionFeeFloor: INIT_REDEMPTION_FEE_FLOOR,
            maxRedemptionFee: INIT_MAX_REDEMPTION_FEE,
            borrowingFeeFloor: INIT_BORROWING_FEE_FLOOR,
            maxBorrowingFee: INIT_MAX_BORROWING_FEE,
            interestRateInBps: INIT_INTEREST_RATE_BPS,
            maxDebt: INIT_MAX_DEBT,
            MCR: INIT_MCR
        });

        vm.expectRevert("Only owner");
        stakedBTCTroveMgr.setParameters(
            params.minuteDecayFactor,
            params.redemptionFeeFloor,
            params.maxRedemptionFee,
            params.borrowingFeeFloor,
            params.maxBorrowingFee,
            params.interestRateInBps,
            params.maxDebt,
            params.MCR
        );
    }

    function _setInterestRate(uint256 newRateInBps) internal {
        IFactory.DeploymentParams memory params = IFactory.DeploymentParams({
            minuteDecayFactor: 999037758833783000,
            redemptionFeeFloor: INIT_REDEMPTION_FEE_FLOOR,
            maxRedemptionFee: INIT_MAX_REDEMPTION_FEE,
            borrowingFeeFloor: INIT_BORROWING_FEE_FLOOR,
            maxBorrowingFee: INIT_MAX_BORROWING_FEE,
            interestRateInBps: newRateInBps,
            maxDebt: INIT_MAX_DEBT,
            MCR: INIT_MCR
        });

        vm.prank(users.owner);
        stakedBTCTroveMgr.setParameters(
            params.minuteDecayFactor,
            params.redemptionFeeFloor,
            params.maxRedemptionFee,
            params.borrowingFeeFloor,
            params.maxBorrowingFee,
            params.interestRateInBps,
            params.maxDebt,
            params.MCR
        );

        assertEq(stakedBTCTroveMgr.lastActiveIndexUpdate(), block.timestamp);

        uint256 expectedNewRate = (TM_INTEREST_PRECISION * params.interestRateInBps) /
            (BIMA_100_PCT * TM_SECONDS_IN_YEAR);

        assertEq(stakedBTCTroveMgr.interestRate(), expectedNewRate);
    }

    function test_setParameters(uint256 newRateInBps) external {
        newRateInBps = bound(newRateInBps, 1, stakedBTCTroveMgr.MAX_INTEREST_RATE_IN_BPS());

        _setInterestRate(newRateInBps);
    }

    // used to store relevant state before tests for verification afterwards
    struct TroveManagerState {
        uint256 defaultedDebt;
        uint256 defaultedCollateral;
        uint256 totalActiveDebt;
        uint256 totalActiveCollateral;
        uint256 interestPayable;
        uint256 activeInterestIndex;
        uint256 lastActiveIndexUpdate;
    }

    function _getTroveManagerState() internal view returns (TroveManagerState memory state) {
        state.defaultedDebt = stakedBTCTroveMgr.defaultedDebt();
        state.defaultedCollateral = stakedBTCTroveMgr.defaultedCollateral();
        state.totalActiveDebt = stakedBTCTroveMgr.getTotalActiveDebt();
        state.totalActiveCollateral = stakedBTCTroveMgr.getTotalActiveCollateral();
        state.interestPayable = stakedBTCTroveMgr.interestPayable();
        state.activeInterestIndex = stakedBTCTroveMgr.activeInterestIndex();
        state.lastActiveIndexUpdate = stakedBTCTroveMgr.lastActiveIndexUpdate();
    }

    function test_accrueActiveInterests(uint256 rateInBps) external {
        rateInBps = bound(rateInBps, 1, stakedBTCTroveMgr.MAX_INTEREST_RATE_IN_BPS());

        _setInterestRate(rateInBps);

        uint256 newInterestRate = stakedBTCTroveMgr.interestRate();

        // save pre state
        TroveManagerState memory statePre = _getTroveManagerState();

        // fast forward 1 week
        uint256 elapsedTime = 1 weeks;
        vm.warp(block.timestamp + elapsedTime);

        // calculate expected parameters
        uint256 interestFactor = elapsedTime * newInterestRate;
        uint256 currentInterestIndex = statePre.activeInterestIndex +
            Math.mulDiv(statePre.activeInterestIndex, interestFactor, TM_INTEREST_PRECISION);
        uint256 newInterest = Math.mulDiv(statePre.totalActiveDebt, interestFactor, TM_INTEREST_PRECISION);

        // test these view functions correctly factor in interest payments
        // even though the call to _accrueActiveInterests has not yet occurred
        assertEq(stakedBTCTroveMgr.getEntireSystemDebt(), statePre.totalActiveDebt + newInterest);
        assertEq(stakedBTCTroveMgr.getTotalActiveDebt(), statePre.totalActiveDebt + newInterest);

        // trigger _accrueActiveInterests
        vm.prank(address(liquidationMgr));
        stakedBTCTroveMgr.updateBalances();

        // save post state
        TroveManagerState memory statePost = _getTroveManagerState();

        // verify new interest added to total active debt and interest payable
        assertEq(statePost.totalActiveDebt, statePre.totalActiveDebt + newInterest);
        assertEq(statePost.interestPayable, statePre.interestPayable + newInterest);

        // verify active interest index updated
        assertNotEq(currentInterestIndex, statePre.activeInterestIndex);
        assertEq(statePost.activeInterestIndex, currentInterestIndex);

        // verify active index update timestamp updated
        assertTrue(statePost.lastActiveIndexUpdate > statePre.lastActiveIndexUpdate);
        assertEq(statePost.lastActiveIndexUpdate, block.timestamp);

        // verify interest payable can be collected
        uint256 feeReceiverDebtTokenBalPre = debtToken.balanceOf(address(feeReceiver));
        stakedBTCTroveMgr.collectInterests();
        assertEq(debtToken.balanceOf(address(feeReceiver)), feeReceiverDebtTokenBalPre + newInterest);
    }

    function test_adjustTrove(
        uint256 _initialColl,
        uint256 _initialDebt,
        uint256 _finalColl,
        uint256 _finalDebt,
        uint256 _btcPrice
    ) public {
        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        (uint256 actualInitialCollateralAmount, uint256 actualInitialDebtAmount) = test_openTrove(
            _initialColl,
            _initialDebt,
            _btcPrice
        );

        _finalColl = bound(_finalColl, minCollateral, maxCollateral);
        _finalDebt = bound(_finalDebt, minDebt, _getMaxDebtAmount(_finalColl));

        vm.startPrank(users.user1);

        if (_finalColl > actualInitialCollateralAmount) {
            deal(address(stakedBTC), users.user1, _finalColl - actualInitialCollateralAmount, true);
            stakedBTC.approve(address(borrowerOps), type(uint256).max);
        }

        borrowerOps.adjustTrove(
            stakedBTCTroveMgr,
            users.user1,
            0,
            _finalColl > actualInitialCollateralAmount ? _finalColl - actualInitialCollateralAmount : 0,
            _finalColl > actualInitialCollateralAmount ? 0 : actualInitialCollateralAmount - _finalColl,
            _finalDebt > actualInitialDebtAmount
                ? _finalDebt - actualInitialDebtAmount
                : actualInitialDebtAmount - _finalDebt,
            _finalDebt > actualInitialDebtAmount,
            address(0),
            address(0)
        );

        // verify trove status unchanged
        assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

        // verify borrower debt tokens
        assertEq(debtToken.balanceOf(users.user1), _finalDebt);

        // verify gas pool compensation tokens unchanged
        assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal + INIT_GAS_COMPENSATION);

        // verify TroveManagers collateral tokens
        assertEq(
            _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
            statePre.troveMgrSBTCBal + _finalColl
        );

        if (_finalColl < actualInitialCollateralAmount)
            assertEq(stakedBTC.balanceOf(users.user1), actualInitialCollateralAmount - _finalColl);

        // verify system balances
        IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
        assertEq(sysBalancesPost.collaterals.length, 1);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
        assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

        assertEq(sysBalancesPost.collaterals[0], statePre.sysBalances.collaterals[0] + _finalColl);
        assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0] + _finalDebt + INIT_GAS_COMPENSATION);
    }

    function test_adjustTrove_when_core_paused_fail(uint256 _collDeposit) public {
        vm.assume(_collDeposit > 0);

        vm.prank(users.guardian);
        bimaCore.setPaused(true);

        vm.prank(users.user1);
        vm.expectRevert("Trove adjustments are paused");
        borrowerOps.adjustTrove(stakedBTCTroveMgr, users.user1, 0, _collDeposit, 0, 0, true, address(0), address(0));
    }

    function test_adjustTrove_repayDebt_when_core_paused_pass(
        uint256 _initialColl,
        uint256 _initialDebt,
        uint256 _finalDebt,
        uint256 _btcPrice
    ) public {
        // save pre state
        BorrowerOpsState memory statePre = _getBorrowerOpsState(users.user1);

        (uint256 actualInitialCollateralAmount, uint256 actualInitialDebtAmount) = test_openTrove(
            _initialColl,
            _initialDebt,
            _btcPrice
        );

        vm.prank(users.guardian);
        bimaCore.setPaused(true);

        _finalDebt = bound(_finalDebt, minDebt, actualInitialDebtAmount);

        vm.startPrank(users.user1);

        // avoid extra bound/assume
        if (_finalDebt != actualInitialDebtAmount) {
            borrowerOps.adjustTrove(
                stakedBTCTroveMgr,
                users.user1,
                0,
                0,
                0,
                actualInitialDebtAmount - _finalDebt,
                false,
                address(0),
                address(0)
            );

            // verify trove status unchanged
            assertEq(uint8(stakedBTCTroveMgr.getTroveStatus(users.user1)), uint8(ITroveManager.Status.active));

            // verify borrower debt tokens
            assertEq(debtToken.balanceOf(users.user1), _finalDebt);

            // verify gas pool compensation tokens unchanged
            assertEq(debtToken.balanceOf(users.gasPool), statePre.gasPoolDebtTokenBal + INIT_GAS_COMPENSATION);

            // verify TroveManagers collateral tokens
            assertEq(
                _wrapperTokenBalance(address(stakedBTC), address(stakedBTCTroveMgr)),
                statePre.troveMgrSBTCBal + actualInitialCollateralAmount
            );

            // verify user hasn't recived any surplus collateral
            assertEq(stakedBTC.balanceOf(users.user1), 0);

            // verify system balances
            IBorrowerOperations.SystemBalances memory sysBalancesPost = borrowerOps.fetchBalances();
            assertEq(sysBalancesPost.collaterals.length, 1);
            assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.debts.length);
            assertEq(sysBalancesPost.collaterals.length, sysBalancesPost.prices.length);

            assertEq(
                sysBalancesPost.collaterals[0],
                statePre.sysBalances.collaterals[0] + actualInitialCollateralAmount
            );
            assertEq(sysBalancesPost.debts[0], statePre.sysBalances.debts[0] + _finalDebt + INIT_GAS_COMPENSATION);
        }
    }

    function test_adjustTrove_ICR_decrease_in_recovery_mode_fail() public {
        _openTroveThenRecoveryMode();

        (, int256 answer, , , ) = mockOracle.latestRoundData();

        uint256 targetICR = (borrowerOps.CCR() * 1.05e18) / 1e18;

        // open trove with ICR little bit higher then CCR, so that during debt decrease afterwards, the new ICR still stays above CCR.
        _openTrove(users.user2, 1e18, (1e18 * uint256(answer) * 1e18) / 1e8 / targetICR - INIT_GAS_COMPENSATION);

        vm.startPrank(users.user2);
        vm.expectRevert("BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode");
        borrowerOps.adjustTrove(stakedBTCTroveMgr, users.user2, 0, 0, 0, 1, true, address(0), address(0));
    }

    function test_fetchPrice_with_priceFeed_zero_address(uint256 btcPrice) external {
        btcPrice = bound(btcPrice, MIN_BTC_PRICE_8DEC, MAX_BTC_PRICE_8DEC);

        // set new btc price with mock oracle
        mockOracle.setResponse(
            mockOracle.roundId() + 1,
            int256(btcPrice),
            block.timestamp + 1,
            block.timestamp + 1,
            mockOracle.answeredInRound() + 1
        );

        skip(1);

        vm.prank(users.owner);
        stakedBTCTroveMgr.setPriceFeed(address(0));

        assertEq(stakedBTCTroveMgr.fetchPrice(), btcPrice * 1e10);
    }
}
