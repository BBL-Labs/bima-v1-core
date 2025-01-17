// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BimaOwnable} from "../dependencies/BimaOwnable.sol";
import {SystemStart} from "../dependencies/SystemStart.sol";
import {BimaMath} from "../dependencies/BimaMath.sol";
import {BIMA_DECIMAL_PRECISION, BIMA_SCALE_FACTOR, BIMA_REWARD_DURATION} from "../dependencies/Constants.sol";
import {IStabilityPool, IDebtToken, IBimaVault, IERC20} from "../interfaces/IStabilityPool.sol";

import {TokenWrapperFactory, TokenWrapper} from "../wrappers/TokenWrapper.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
    @title Bima Stability Pool
    @notice Based on Liquity's `StabilityPool`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/StabilityPool.sol

            Bima's implementation is modified to support multiple collaterals. Deposits into
            the stability pool may be used to liquidate any supported collateral type.
 */
contract StabilityPool is IStabilityPool, BimaOwnable, SystemStart {
    using SafeERC20 for IERC20;

    // constants
    uint128 public constant SUNSET_DURATION = 180 days;
    uint256 constant MAX_COLLATERAL_COUNT = 256;

    // stability pool is registered with receiver ID 0
    // in BimaVault::constructor
    uint256 public constant SP_EMISSION_ID = 0;

    // immutable
    IDebtToken public immutable debtToken;
    IBimaVault public immutable vault;
    address public immutable factory;
    address public immutable liquidationManager;

    TokenWrapperFactory public immutable tokenWrapperFactory;

    // public
    //
    // reward issuance rate for all depositors
    uint128 public rewardRate;

    // used with rewardRate to calculate actual rewards
    // based on time duration since last update
    uint32 public lastUpdate;

    // used to periodically trigger calls to BimaVault::allocateNewEmissions
    uint32 public periodFinish;

    // here for storage packing
    SunsetQueue queue;

    // Each time the scale of P shifts by BIMA_SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    // Error tracker for the error correction in the Bima issuance calculation
    uint256 public lastBimaError;
    // Error trackers for the error correction in the offset calculation
    uint256[MAX_COLLATERAL_COUNT] public lastCollateralError_Offset;
    uint256 public lastDebtLossError_Offset;

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
     * after a series of liquidations have occurred, each of which cancel some debt with the deposit.
     *
     * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
     * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
     */
    uint256 public P = BIMA_DECIMAL_PRECISION;

    // internal
    //
    // Tracker for Debt held in the pool, changes when users deposit/withdraw
    // and when Trove debt is offset
    uint256 internal totalDebtTokenDeposits;

    // public array
    IERC20[] public collateralTokens;

    // mappings
    //
    // collateral -> (index+1) in collateralTokens
    // sunsetting collateral has index = 0
    // newest collateral has index = collateralTokens.length
    mapping(IERC20 collateral => uint256 index) public indexByCollateral;

    mapping(address depositor => AccountDeposit) public accountDeposits;
    mapping(address depositor => Snapshots) public depositSnapshots;

    // index values are mapped against the values within `collateralTokens`
    mapping(address depositor => uint256[MAX_COLLATERAL_COUNT] deposits) public depositSums;

    mapping(address depositor => uint80[MAX_COLLATERAL_COUNT] gains) public collateralGainsByDepositor;

    mapping(address depositor => uint256 rewards) private storedPendingReward;

    /* collateral Gain sum 'S': During its lifetime, each deposit d_t earns a collateral gain of ( d_t * [S - S_t] )/P_t, where S_t
     * is the depositor's snapshot of S taken at the time t when the deposit was made.
     *
     * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
     *
     * - The inner mapping records the sum S at different scales
     * - The outer mapping records the (scale => sum) mappings, for different epochs.
     */

    // index values are mapped against the values within `collateralTokens`
    mapping(uint128 epoch => mapping(uint128 scale => uint256[MAX_COLLATERAL_COUNT] sumS)) public epochToScaleToSums;

    /*
     * Similarly, the sum 'G' is used to calculate Bima gains. During it's lifetime, each deposit d_t earns a Bima gain of
     *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
     *
     *  Bima reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
     *  In each case, the Bima reward is issued (i.e. G is updated), before other state changes are made.
     */
    mapping(uint128 epoch => mapping(uint128 scale => uint256 sumG)) public epochToScaleToG;

    mapping(uint16 indexKey => SunsetIndex) _sunsetIndexes;

    // structs
    struct AccountDeposit {
        uint128 amount;
        uint128 timestamp; // timestamp of the last deposit
    }
    struct Snapshots {
        uint256 P;
        uint256 G;
        uint128 scale;
        uint128 epoch;
    }
    struct SunsetIndex {
        uint128 idx;
        uint128 expiry;
    }
    struct SunsetQueue {
        uint16 firstSunsetIndexKey;
        uint16 nextSunsetIndexKey;
    }

    constructor(
        address _bimaCore,
        IDebtToken _debtTokenAddress,
        IBimaVault _vault,
        address _factory,
        address _liquidationManager,
        TokenWrapperFactory _tokenWrapperFactory
    ) BimaOwnable(_bimaCore) SystemStart(_bimaCore) {
        debtToken = _debtTokenAddress;
        vault = _vault;
        factory = _factory;
        liquidationManager = _liquidationManager;
        periodFinish = uint32(block.timestamp - 1);
        tokenWrapperFactory = _tokenWrapperFactory;
    }

    function enableCollateral(IERC20 _collateral) external {
        // factory always calls this function when deploying new
        // instances of `TroveManager` and `SortedTroves` to enable
        require(msg.sender == factory, "Not factory");

        // search through all existing collateral tokens to determine
        // whether this collateral token is already enabled
        uint256 length = collateralTokens.length;

        // enforce maximum number of collaterals
        require(length != MAX_COLLATERAL_COUNT, "Maximum collateral length reached");

        bool alreadyEnabled;

        for (uint256 i; i < length; i++) {
            if (collateralTokens[i] == _collateral) {
                alreadyEnabled = true;
                break;
            }
        }

        // if collateral is not already enabled
        if (!alreadyEnabled) {
            // cache the sunset queue
            SunsetQueue memory queueCached = queue;

            // if possible, over-write a sunsetting collateral
            // ready to be removed with this new collateral
            if (queueCached.nextSunsetIndexKey > queueCached.firstSunsetIndexKey) {
                SunsetIndex memory sIdx = _sunsetIndexes[queueCached.firstSunsetIndexKey];

                if (sIdx.expiry < block.timestamp) {
                    delete _sunsetIndexes[queueCached.firstSunsetIndexKey];
                    ++queue.firstSunsetIndexKey;

                    _overwriteCollateral(_collateral, sIdx.idx);
                    return;
                }
            }

            // otherwise just add new collateral
            collateralTokens.push(_collateral);
            indexByCollateral[_collateral] = length + 1;
        }
        // if collateral was already enabled, then revert if the factory is trying
        // to deploy a new TroveManager with a sunsetting collateral
        else {
            require(indexByCollateral[_collateral] > 0, "Collateral is sunsetting");
        }
    }

    function _overwriteCollateral(IERC20 _newCollateral, uint256 idx) internal {
        // only sunset collateral can be overwritten
        require(indexByCollateral[_newCollateral] == 0, "Collateral must be sunset");

        // cache number of collateral tokens
        uint256 length = collateralTokens.length;

        // index to remove must be valid
        require(idx < length, "Index too large");

        uint256 externalLoopEnd = currentEpoch;
        uint256 internalLoopEnd = currentScale;

        for (uint128 i; i <= externalLoopEnd; ) {
            for (uint128 j; j <= internalLoopEnd; ) {
                // reset collateral gain sum 'S' for collateral being removed
                epochToScaleToSums[i][j][idx] = 0;
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        // update index of new collateral; note that `indexByCollateral`
        // stores (index + 1) eg [1...collateralTokens.length]
        indexByCollateral[_newCollateral] = idx + 1;

        // emit event(old, new) prior to over-writing
        emit CollateralOverwritten(collateralTokens[idx], _newCollateral);

        // overwrite old collateral with new one
        collateralTokens[idx] = _newCollateral;
    }

    /**
     * @notice Starts sunsetting a collateral
     *         During sunsetting liquidated collateral handoff to the SP will revert
        @dev IMPORTANT: When sunsetting a collateral, `TroveManager.startSunset`
                        should be called on all TM linked to that collateral
        @param collateral Collateral to sunset

     */
    function startCollateralSunset(IERC20 collateral) external onlyOwner {
        uint256 indexCache = indexByCollateral[collateral];

        // can't sunset an already sunsetting collateral
        require(indexCache > 0, "Collateral already sunsetting");

        // add sunsetting collateral to sunset mapping
        _sunsetIndexes[queue.nextSunsetIndexKey++] = SunsetIndex(
            uint128(indexCache - 1),
            uint128(block.timestamp + SUNSET_DURATION)
        );

        // prevents calls to the StabilityPool in case of liquidations
        delete indexByCollateral[collateral];
    }

    function getNumCollateralTokens() external view returns (uint256 count) {
        count = collateralTokens.length;
    }

    function getSunsetQueueKeys() external view returns (uint16 firstSunsetIndexKey, uint16 nextSunsetIndexKey) {
        SunsetQueue memory data = queue;
        (firstSunsetIndexKey, nextSunsetIndexKey) = (data.firstSunsetIndexKey, data.nextSunsetIndexKey);
    }

    function getSunsetIndexes(uint16 indexKey) external view returns (uint128 idx, uint128 expiry) {
        SunsetIndex memory data = _sunsetIndexes[indexKey];
        (idx, expiry) = (data.idx, data.expiry);
    }

    function getTotalDebtTokenDeposits() external view returns (uint256 output) {
        output = totalDebtTokenDeposits;
    }

    function getStoredPendingReward(address depositor) external view returns (uint256 reward) {
        reward = storedPendingReward[depositor];
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
     *
     * - Triggers a Bima issuance, based on time passed since the last issuance.
     *   The Bima issuance is shared between *all* depositors and front ends
     * - Tags the deposit with the provided front end tag param, if it's a new deposit
     * - Sends depositor's accumulated gains (Bima, collateral) to depositor
     * - Sends the tagged front end's accumulated Bima gains to the tagged front end
     * - Increases deposit and tagged front end's stake, and takes new snapshots for each.
     */
    function provideToSP(uint256 _amount) external {
        require(!BIMA_CORE.paused(), "Deposits are paused");
        require(_amount > 0, "StabilityPool: Amount must be non-zero");

        // perform processes prior to crediting new deposit
        _triggerRewardIssuance();
        _accrueDepositorCollateralGain(msg.sender);

        uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(msg.sender);
        _accrueRewards(msg.sender);

        // transfer the tokens being deposited
        debtToken.sendToSP(msg.sender, _amount);

        // update storage increase total debt tokens deposited
        uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits + _amount;
        totalDebtTokenDeposits = newTotalDebtTokenDeposits;
        emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);

        // update storage user deposit record
        uint256 newTotalDeposited = compoundedDebtDeposit + _amount;

        accountDeposits[msg.sender] = AccountDeposit({
            amount: SafeCast.toUint128(newTotalDeposited),
            timestamp: uint128(block.timestamp)
        });

        _updateSnapshots(msg.sender, newTotalDeposited);
        emit UserDepositChanged(msg.sender, newTotalDeposited);
    }

    /*  withdrawFromSP():
     *
     * - Triggers a Bima issuance, based on time passed since the last issuance.
     *   The Bima issuance is shared between *all* depositors and front ends
     * - Removes the deposit's front end tag if it is a full withdrawal
     * - Sends all depositor's accumulated gains (Bima, collateral) to depositor
     * - Sends the tagged front end's accumulated Bima gains to the tagged front end
     * - Decreases deposit and tagged front end's stake, and takes new snapshots for each.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdrawFromSP(uint256 _amount) external {
        // 1 SLOAD since amount & timestamp fit in same slot
        AccountDeposit memory accountCache = accountDeposits[msg.sender];

        require(accountCache.amount > 0, "StabilityPool: User must have a non-zero deposit");
        require(accountCache.timestamp < block.timestamp, "!Deposit and withdraw same block");

        // perform processes prior to debiting new withdrawal
        _triggerRewardIssuance();
        _accrueDepositorCollateralGain(msg.sender);

        uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(msg.sender);
        uint256 debtToWithdraw = BimaMath._min(_amount, compoundedDebtDeposit);
        _accrueRewards(msg.sender);

        // transfer the tokens being withdrawn
        if (debtToWithdraw > 0) {
            debtToken.returnFromPool(address(this), msg.sender, debtToWithdraw);

            // update storage decrease total debt tokens deposited
            _decreaseDebt(debtToWithdraw);
        }

        // update storage user deposit record
        uint256 newTotalDeposited = compoundedDebtDeposit - debtToWithdraw;

        // note: timestamp doesn't change as it is always timestamp
        // of last deposit, so withdrawal doesn't change this
        accountDeposits[msg.sender].amount = SafeCast.toUint128(newTotalDeposited);

        _updateSnapshots(msg.sender, newTotalDeposited);
        emit UserDepositChanged(msg.sender, newTotalDeposited);
    }

    // --- Bima issuance functions ---

    function _triggerRewardIssuance() internal {
        _updateG(_vestedEmissions());

        uint256 _periodFinish = periodFinish;
        uint256 lastUpdateWeek = (_periodFinish - startTime) / 1 weeks;

        // if the current system week is the same as the last update week
        // or if the last update week was in the past, then claim new
        // emissions from BimaVault
        if (getWeek() >= lastUpdateWeek) {
            uint256 amount = vault.allocateNewEmissions(SP_EMISSION_ID);

            if (amount > 0) {
                // If the previous period is not finished we combine new and pending old rewards
                if (block.timestamp < _periodFinish) {
                    uint256 remaining = _periodFinish - block.timestamp;
                    amount += remaining * rewardRate;
                }

                rewardRate = SafeCast.toUint128(amount / BIMA_REWARD_DURATION);
                periodFinish = uint32(block.timestamp + BIMA_REWARD_DURATION);
            }
        }

        lastUpdate = uint32(block.timestamp);
    }

    function _vestedEmissions() internal view returns (uint256 bimaIssuance) {
        uint256 updated = periodFinish;

        // Period is not ended we max at current timestamp
        if (updated > block.timestamp) updated = block.timestamp;

        // if the last update was after the current update time
        // it means all rewards have been vested already so return
        // default zero
        uint256 lastUpdateCached = lastUpdate;

        // otherwise calculate vested emissions
        if (lastUpdateCached < updated) {
            uint256 duration = updated - lastUpdateCached;
            bimaIssuance = duration * rewardRate;
        }
    }

    function _updateG(uint256 _bimaIssuance) internal {
        uint256 totalDebt = totalDebtTokenDeposits;

        // When total deposits is 0, G is not updated. In this case
        // the Bima issued can not be obtained by later depositors;
        // it is missed out on, and remains in the balanceOf the Treasury contract.
        if (totalDebt == 0 || _bimaIssuance == 0) {
            return;
        }

        uint256 bimaPerUnitStaked;
        bimaPerUnitStaked = _computeBimaPerUnitStaked(_bimaIssuance, totalDebt);

        uint128 currentEpochCached = currentEpoch;
        uint128 currentScaleCached = currentScale;

        uint256 marginalBimaGain = bimaPerUnitStaked * P;
        uint256 newG = epochToScaleToG[currentEpochCached][currentScaleCached] + marginalBimaGain;

        epochToScaleToG[currentEpochCached][currentScaleCached] = newG;

        emit G_Updated(newG, currentEpochCached, currentScaleCached);
    }

    function _computeBimaPerUnitStaked(
        uint256 _bimaIssuance,
        uint256 _totalDebtTokenDeposits
    ) internal returns (uint256 bimaPerUnitStaked) {
        /*
         * Calculate the Bima-per-unit staked.  Division uses a "feedback" error correction, to keep the
         * cumulative error low in the running total G:
         *
         * 1) Form a numerator which compensates for the floor division error that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratio.
         * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
         * 4) Store this error for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 bimaNumerator = (_bimaIssuance * BIMA_DECIMAL_PRECISION) + lastBimaError;

        bimaPerUnitStaked = bimaNumerator / _totalDebtTokenDeposits;
        lastBimaError = bimaNumerator - (bimaPerUnitStaked * _totalDebtTokenDeposits);
    }

    // --- Liquidation functions ---

    /*
     * Cancels out the specified debt against the Debt contained in the Stability Pool (as far as possible)
     */
    function offset(IERC20 collateral, uint256 _debtToOffset, uint256 _collToAdd) external virtual {
        _offset(collateral, _debtToOffset, _collToAdd);
    }

    function _offset(IERC20 collateral, uint256 _debtToOffset, uint256 _collToAdd) internal {
        require(msg.sender == liquidationManager, "StabilityPool: Caller is not Liquidation Manager");
        uint256 idx = indexByCollateral[collateral];
        idx -= 1;

        uint256 totalDebt = totalDebtTokenDeposits;
        if (totalDebt == 0 || _debtToOffset == 0) {
            return;
        }

        _triggerRewardIssuance();

        (uint256 collateralGainPerUnitStaked, uint256 debtLossPerUnitStaked) = _computeRewardsPerUnitStaked(
            _collToAdd,
            _debtToOffset,
            totalDebt,
            idx
        );

        // update S and P
        _updateRewardSumAndProduct(collateralGainPerUnitStaked, debtLossPerUnitStaked, idx);

        // Cancel the liquidated Debt debt with the Debt in the stability pool
        _decreaseDebt(_debtToOffset);
    }

    // --- Offset helper functions ---

    function _computeRewardsPerUnitStaked(
        uint256 _collToAdd,
        uint256 _debtToOffset,
        uint256 _totalDebtTokenDeposits,
        uint256 idx
    ) internal returns (uint256 collateralGainPerUnitStaked, uint256 debtLossPerUnitStaked) {
        /*
         * Compute the Debt and collateral rewards. Uses a "feedback" error correction, to keep
         * the cumulative error in the P and S state variables low:
         *
         * 1) Form numerators which compensate for the floor division errors that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratios.
         * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
         * 4) Store these errors for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 collateralNumerator = (_collToAdd * BIMA_DECIMAL_PRECISION) + lastCollateralError_Offset[idx];

        if (_debtToOffset == _totalDebtTokenDeposits) {
            debtLossPerUnitStaked = BIMA_DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit
            lastDebtLossError_Offset = 0;
        } else {
            uint256 debtLossNumerator = (_debtToOffset * BIMA_DECIMAL_PRECISION) - lastDebtLossError_Offset;
            /*
             * Add 1 to make error in quotient positive. We want "slightly too much" Debt loss,
             * which ensures the error in any given compoundedDebtDeposit favors the Stability Pool.
             */
            debtLossPerUnitStaked = (debtLossNumerator / _totalDebtTokenDeposits) + 1;
            lastDebtLossError_Offset = (debtLossPerUnitStaked * _totalDebtTokenDeposits) - debtLossNumerator;
        }

        collateralGainPerUnitStaked = collateralNumerator / _totalDebtTokenDeposits;
        lastCollateralError_Offset[idx] = collateralNumerator - (collateralGainPerUnitStaked * _totalDebtTokenDeposits);
    }

    // Update the Stability Pool reward sum S and product P
    function _updateRewardSumAndProduct(
        uint256 _collateralGainPerUnitStaked,
        uint256 _debtLossPerUnitStaked,
        uint256 idx
    ) internal {
        uint256 currentP = P;
        uint256 newP;

        /*
         * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool Debt in the liquidation.
         * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - DebtLossPerUnitStaked)
         */
        uint256 newProductFactor = BIMA_DECIMAL_PRECISION - _debtLossPerUnitStaked;

        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentS = epochToScaleToSums[currentEpochCached][currentScaleCached][idx];

        /*
         * Calculate the new S first, before we update P.
         * The collateral gain for any given depositor from a liquidation depends on the value of their deposit
         * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
         *
         * Since S corresponds to collateral gain, and P to deposit loss, we update S first.
         */
        uint256 marginalCollateralGain = _collateralGainPerUnitStaked * currentP;
        uint256 newS = currentS + marginalCollateralGain;
        epochToScaleToSums[currentEpochCached][currentScaleCached][idx] = newS;
        emit S_Updated(idx, newS, currentEpochCached, currentScaleCached);

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpoch = currentEpochCached + 1;
            emit EpochUpdated(currentEpoch);
            currentScale = 0;
            emit ScaleUpdated(currentScale);
            newP = BIMA_DECIMAL_PRECISION;

            // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else if ((currentP * newProductFactor) / BIMA_DECIMAL_PRECISION < BIMA_SCALE_FACTOR) {
            newP = (currentP * newProductFactor * BIMA_SCALE_FACTOR) / BIMA_DECIMAL_PRECISION;
            currentScale = currentScaleCached + 1;
            emit ScaleUpdated(currentScale);
        } else {
            newP = (currentP * newProductFactor) / BIMA_DECIMAL_PRECISION;
        }

        require(newP > 0, "NewP");
        P = newP;
        emit P_Updated(newP);
    }

    function _decreaseDebt(uint256 _amount) internal {
        uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits - _amount;
        totalDebtTokenDeposits = newTotalDebtTokenDeposits;
        emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);
    }

    // --- Reward calculator functions for depositor and front end ---

    /* Calculates the collateral gain earned by the deposit since its last snapshots were taken.
     * Given by the formula:  E = d0 * (S - S(0))/P(0)
     * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
     * d0 is the last recorded deposit value.
     */
    function getDepositorCollateralGain(address _depositor) external view returns (uint256[] memory collateralGains) {
        collateralGains = new uint256[](collateralTokens.length);

        uint256 P_Snapshot = depositSnapshots[_depositor].P;
        if (P_Snapshot == 0) return collateralGains;
        uint80[MAX_COLLATERAL_COUNT] storage depositorGains = collateralGainsByDepositor[_depositor];
        uint256 initialDeposit = accountDeposits[_depositor].amount;
        uint128 epochSnapshot = depositSnapshots[_depositor].epoch;
        uint128 scaleSnapshot = depositSnapshots[_depositor].scale;
        uint256[MAX_COLLATERAL_COUNT] storage sums = epochToScaleToSums[epochSnapshot][scaleSnapshot];
        uint256[MAX_COLLATERAL_COUNT] storage nextSums = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1];
        uint256[MAX_COLLATERAL_COUNT] storage depSums = depositSums[_depositor];

        for (uint256 i; i < collateralGains.length; i++) {
            collateralGains[i] = depositorGains[i];
            if (sums[i] == 0) continue; // Collateral was overwritten or not gains
            uint256 firstPortion = sums[i] - depSums[i];
            uint256 secondPortion = nextSums[i] / BIMA_SCALE_FACTOR;
            collateralGains[i] +=
                (initialDeposit * (firstPortion + secondPortion)) /
                P_Snapshot /
                BIMA_DECIMAL_PRECISION;
        }
    }

    function _accrueDepositorCollateralGain(address _depositor) private returns (bool hasGains) {
        // get storage reference to user's collateral gains
        uint80[MAX_COLLATERAL_COUNT] storage depositorGains = collateralGainsByDepositor[_depositor];

        // cache number of collateral tokens
        uint256 collaterals = collateralTokens.length;

        // cache user's initial deposit amount
        uint256 initialDeposit = accountDeposits[_depositor].amount;

        if (initialDeposit != 0) {
            uint128 epochSnapshot = depositSnapshots[_depositor].epoch;
            uint128 scaleSnapshot = depositSnapshots[_depositor].scale;
            uint256 P_Snapshot = depositSnapshots[_depositor].P;

            uint256[MAX_COLLATERAL_COUNT] storage sumS = epochToScaleToSums[epochSnapshot][scaleSnapshot];
            uint256[MAX_COLLATERAL_COUNT] storage nextSumS = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1];
            uint256[MAX_COLLATERAL_COUNT] storage depSums = depositSums[_depositor];

            for (uint256 i; i < collaterals; i++) {
                if (sumS[i] == 0) continue; // Collateral was overwritten or not gains

                hasGains = true;

                uint256 firstPortion = sumS[i] - depSums[i];
                uint256 secondPortion = nextSumS[i] / BIMA_SCALE_FACTOR;

                depositorGains[i] += SafeCast.toUint80(
                    (initialDeposit * (firstPortion + secondPortion)) / P_Snapshot / BIMA_DECIMAL_PRECISION
                );
            }
        }
    }

    /*
     * Calculate the Bima gain earned by a deposit since its last snapshots were taken.
     * Given by the formula:  Bima = d0 * (G - G(0))/P(0)
     * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
     * d0 is the last recorded deposit value.
     */
    function claimableReward(address _depositor) external view returns (uint256 reward) {
        uint256 totalDebt = totalDebtTokenDeposits;
        uint256 initialDeposit = accountDeposits[_depositor].amount;

        // first output stored pending reward
        reward = storedPendingReward[_depositor];

        // if depositor has deposits & debt perform additional calculations
        if (totalDebt != 0 && initialDeposit != 0) {
            uint256 bimaNumerator = (_vestedEmissions() * BIMA_DECIMAL_PRECISION) + lastBimaError;
            uint256 bimaPerUnitStaked = bimaNumerator / totalDebt;

            Snapshots memory snapshots = depositSnapshots[_depositor];
            uint128 epochSnapshot = snapshots.epoch;
            uint128 scaleSnapshot = snapshots.scale;
            uint256 firstPortion;
            uint256 secondPortion;

            uint256 marginalBimaGain = epochSnapshot == currentEpoch ? bimaPerUnitStaked * P : 0;

            if (scaleSnapshot == currentScale) {
                firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - snapshots.G + marginalBimaGain;
                secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot + 1] / BIMA_SCALE_FACTOR;
            } else {
                firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - snapshots.G;
                secondPortion =
                    (epochToScaleToG[epochSnapshot][scaleSnapshot + 1] + marginalBimaGain) /
                    BIMA_SCALE_FACTOR;
            }

            // add additional calculation to stored pending reward already in output
            reward += (initialDeposit * (firstPortion + secondPortion)) / snapshots.P / BIMA_DECIMAL_PRECISION;
        } else {
            reward += _claimableReward(_depositor);
        }
    }

    function _claimableReward(address _depositor) private view returns (uint256 reward) {
        // output account deposit
        reward = accountDeposits[_depositor].amount;

        // only process reward calculation if account has > 0 deposit
        if (reward != 0) {
            Snapshots memory snapshots = depositSnapshots[_depositor];

            reward = _getBimaGainFromSnapshots(reward, snapshots);
        }
    }

    function _getBimaGainFromSnapshots(
        uint256 initialStake,
        Snapshots memory snapshots
    ) internal view returns (uint256 bimaGain) {
        /*
         * Grab the sum 'G' from the epoch at which the stake was made.
         * The Bima gain may span up to one scale change.
         * If it does, the second portion of the Bima gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;

        uint256 G_Snapshot = snapshots.G;
        uint256 P_Snapshot = snapshots.P;

        uint256 firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - G_Snapshot;
        uint256 secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot + 1] / BIMA_SCALE_FACTOR;

        bimaGain = (initialStake * (firstPortion + secondPortion)) / P_Snapshot / BIMA_DECIMAL_PRECISION;
    }

    // --- Compounded deposit and compounded front end stake ---

    /*
     * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
     * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
     */
    function getCompoundedDebtDeposit(address _depositor) public view returns (uint256 compoundedDeposit) {
        // output account deposit
        compoundedDeposit = accountDeposits[_depositor].amount;

        // only process compounded deposit if account has > 0 deposit
        if (compoundedDeposit != 0) {
            Snapshots memory snapshots = depositSnapshots[_depositor];

            compoundedDeposit = _getCompoundedStakeFromSnapshots(compoundedDeposit, snapshots);
        }
    }

    // Internal function, used to calculcate compounded deposits and compounded front end stakes.
    function _getCompoundedStakeFromSnapshots(
        uint256 initialStake,
        Snapshots memory snapshots
    ) internal view returns (uint256 compoundedStake) {
        // If stake was made before a pool-emptying event (epochSnapshot < currentEpoch)
        // then it has been fully cancelled with debt so return default 0 value - nothing to do
        if (snapshots.epoch >= currentEpoch) {
            uint128 scaleDiff = currentScale - snapshots.scale;

            /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
             * account for it. If more than one scale change was made, then the stake has decreased by a factor of
             * at least 1e-9 -- so return 0.
             */
            if (scaleDiff == 0) {
                compoundedStake = (initialStake * P) / snapshots.P;
            } else if (scaleDiff == 1) {
                compoundedStake = (initialStake * P) / snapshots.P / BIMA_SCALE_FACTOR;
            }
            // if scaleDiff >= 2, return default zero value
        }
    }

    // --- Sender functions for Debt deposit, collateral gains and Bima gains ---
    function claimCollateralGains(address recipient, uint256[] calldata collateralIndexes) external {
        // trigger reward claims prior to claiming collateral gains
        claimReward(recipient);

        uint256[] memory collateralGains = new uint256[](collateralTokens.length);

        uint80[MAX_COLLATERAL_COUNT] storage depositorGains = collateralGainsByDepositor[msg.sender];

        // more efficient not to cache calldata input length
        for (uint256 i; i < collateralIndexes.length; ) {
            uint256 collateralIndex = collateralIndexes[i];
            uint256 gains = depositorGains[collateralIndex];

            if (gains > 0) {
                collateralGains[collateralIndex] = gains;
                depositorGains[collateralIndex] = 0;

                IERC20 collateralToken = collateralTokens[collateralIndex];

                uint256 unwrappedAmount = tokenWrapperFactory.getWrapper(collateralToken).unwrap(gains);

                collateralToken.safeTransfer(recipient, unwrappedAmount);
            }
            unchecked {
                ++i;
            }
        }

        emit CollateralGainWithdrawn(msg.sender, collateralGains);
    }

    // --- Stability Pool Deposit Functionality ---

    function _updateSnapshots(address _depositor, uint256 _newValue) internal {
        // if resetting depositor snapshots when the depositor withdraws everything
        if (_newValue == 0) {
            delete depositSnapshots[_depositor];

            uint256 length = collateralTokens.length;

            for (uint256 i; i < length; i++) {
                depositSums[_depositor][i] = 0;
            }

            emit DepositSnapshotUpdated(_depositor, 0, 0);
        } else {
            uint128 currentScaleCached = currentScale;
            uint128 currentEpochCached = currentEpoch;
            uint256 currentP = P;

            // Get S and G for the current epoch and current scale
            uint256[MAX_COLLATERAL_COUNT] storage currentS = epochToScaleToSums[currentEpochCached][currentScaleCached];
            uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

            // Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
            depositSnapshots[_depositor].P = currentP;
            depositSnapshots[_depositor].G = currentG;
            depositSnapshots[_depositor].scale = currentScaleCached;
            depositSnapshots[_depositor].epoch = currentEpochCached;

            uint256 length = collateralTokens.length;

            for (uint256 i; i < length; i++) {
                depositSums[_depositor][i] = currentS[i];
            }

            emit DepositSnapshotUpdated(_depositor, currentP, currentG);
        }
    }

    // This assumes the snapshot gets updated in the caller
    function _accrueRewards(address _depositor) internal {
        uint256 amount = _claimableReward(_depositor);

        storedPendingReward[_depositor] += amount;
    }

    function claimReward(address recipient) public returns (uint256 amount) {
        amount = _claimReward(msg.sender);

        if (amount > 0) {
            vault.transferAllocatedTokens(msg.sender, recipient, amount);
        }

        emit RewardClaimed(msg.sender, recipient, amount);
    }

    function vaultClaimReward(address claimant, address) external returns (uint256 amount) {
        require(msg.sender == address(vault), "!vault");

        amount = _claimReward(claimant);
    }

    function _claimReward(address account) internal returns (uint256 amount) {
        uint256 initialDeposit = accountDeposits[account].amount;

        if (initialDeposit > 0) {
            _triggerRewardIssuance();
            bool hasGains = _accrueDepositorCollateralGain(account);

            uint256 compoundedDebtDeposit = getCompoundedDebtDeposit(account);
            uint256 debtLoss = initialDeposit - compoundedDebtDeposit;

            amount = _claimableReward(account);

            // we update only if the snapshot has changed
            if (debtLoss > 0 || hasGains || amount > 0) {
                // Update deposit
                accountDeposits[account].amount = SafeCast.toUint128(compoundedDebtDeposit);
                _updateSnapshots(account, compoundedDebtDeposit);
            }
        }

        uint256 pending = storedPendingReward[account];

        if (pending > 0) {
            amount += pending;
            storedPendingReward[account] = 0;
        }
    }
}
