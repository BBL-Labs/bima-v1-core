// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";
import {ITroveManager, IDebtToken, IBimaVault, IPriceFeed, ISortedTroves, IERC20} from "../interfaces/ITroveManager.sol";
import {SystemStart} from "../dependencies/SystemStart.sol";
import {BimaBase} from "../dependencies/BimaBase.sol";
import {BimaMath} from "../dependencies/BimaMath.sol";
import {BimaOwnable} from "../dependencies/BimaOwnable.sol";
import {BIMA_100_PCT, BIMA_DECIMAL_PRECISION, BIMA_REWARD_DURATION} from "../dependencies/Constants.sol";

import {TokenWrapperFactory, TokenWrapper} from "../wrappers/TokenWrapper.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
    @title Bima Trove Manager
    @notice Based on Liquity's `TroveManager`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/TroveManager.sol

            Bima's implementation is modified so that multiple `TroveManager` and `SortedTroves`
            contracts are deployed in tandem, with each pair managing troves of a single collateral
            type.

            Functionality related to liquidations has been moved to `LiquidationManager`. This was
            necessary to avoid the restriction on deployed bytecode size.
 */
contract TroveManager is ITroveManager, BimaBase, BimaOwnable, SystemStart {
    using SafeERC20 for IERC20;

    // --- Constants ---
    //
    // Minimum Collateral Ratio for individual troves
    uint256 public MCR;

    uint256 constant SECONDS_IN_ONE_MINUTE = 60;
    uint256 constant INTEREST_PRECISION = 1e27;
    uint256 constant SECONDS_IN_YEAR = 365 days;

    // volume-based amounts are divided by this value to allow storing as uint32
    uint256 constant VOLUME_MULTIPLIER = 1e20;

    // Maximum interest rate must be lower than the minimum LST staking yield
    // so that over time the actual TCR becomes greater than the calculated TCR
    uint256 public constant MAX_INTEREST_RATE_IN_BPS = 400; // 4%
    uint256 public constant SUNSETTING_INTEREST_RATE = (INTEREST_PRECISION * 5000) / (BIMA_100_PCT * SECONDS_IN_YEAR); //50%

    // During bootsrap period redemptions are not allowed
    uint256 public constant BOOTSTRAP_PERIOD = 14 days;

    /*
     * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
     * Corresponds to (1 / ALPHA) in the white paper.
     */
    uint256 constant BETA = 2;

    // --- Connected contract declarations ---
    address public immutable borrowerOperationsAddress;
    address public immutable liquidationManager;
    address immutable gasPoolAddress;
    IDebtToken public immutable debtToken;
    IBimaVault public immutable vault;

    TokenWrapperFactory public immutable tokenWrapperFactory;

    IPriceFeed public priceFeed;
    IERC20 public collateralToken;

    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    // --- public ---
    //
    // commented values are Liquity's fixed settings for each parameter
    uint256 public minuteDecayFactor; // 999037758833783000  (half-life of 12 hours)
    uint256 public redemptionFeeFloor; // BIMA_DECIMAL_PRECISION / 1000 * 5  (0.5%)
    uint256 public maxRedemptionFee; // BIMA_DECIMAL_PRECISION  (100%)
    uint256 public borrowingFeeFloor; // BIMA_DECIMAL_PRECISION / 1000 * 5  (0.5%)
    uint256 public maxBorrowingFee; // BIMA_DECIMAL_PRECISION / 100 * 5  (5%)
    uint256 public maxSystemDebt;

    uint256 public interestRate;
    uint256 public activeInterestIndex;
    uint256 public lastActiveIndexUpdate;

    uint256 public systemDeploymentTime;

    uint256 public baseRate;

    // The timestamp of the latest fee operation (redemption or new debt issuance)
    uint256 public lastFeeOperationTime;

    uint256 public totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
    uint256 public totalStakesSnapshot;

    // Snapshot of the total collateral taken immediately after the latest liquidation.
    uint256 public totalCollateralSnapshot;

    /*
     * L_collateral and L_debt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
     *
     * An collateral gain of ( stake * [L_collateral - L_collateral(0)] )
     * A debt increase  of ( stake * [L_debt - L_debt(0)] )
     *
     * Where L_collateral(0) and L_debt(0) are snapshots of L_collateral and L_debt for the active Trove taken at the instant the stake was made
     */
    uint256 public L_collateral;
    uint256 public L_debt;

    // Error trackers for the trove redistribution calculation
    uint256 public lastCollateralError_Redistribution;
    uint256 public lastDebtError_Redistribution;

    uint256 internal totalActiveCollateral;
    uint256 internal totalActiveDebt;
    uint256 public interestPayable;

    uint256 public defaultedCollateral;
    uint256 public defaultedDebt;

    uint256 public rewardIntegral;
    uint128 public rewardRate;
    uint32 public lastUpdate;
    uint32 public periodFinish;

    // here for storage packing
    bool public sunsetting;
    bool public paused;
    EmissionId public emissionId;

    // --- array ---
    //
    // week -> total available rewards for 1 day within this week
    uint256[65535] public dailyMintReward;

    // week -> day -> total amount redeemed this day
    uint32[7][65535] private totalMints;

    // Array of all active trove addresses - used to compute
    // an approximate hint off-chain, for the sorted list insertion
    address[] TroveOwners;

    // --- mapping ---
    //
    mapping(address account => uint256 rewardIntegral) public rewardIntegralFor;
    mapping(address account => uint256 pendingReward) private storedPendingReward;

    // account -> data for latest activity
    mapping(address account => VolumeData mintData) public accountLatestMint;

    mapping(address borrower => Trove borrowerData) public Troves;
    mapping(address borrower => uint256 surplusCollateral) public surplusBalances;

    // Map addresses with active troves to their RewardSnapshot
    mapping(address borrower => RewardSnapshot) public rewardSnapshots;

    struct VolumeData {
        uint32 amount;
        uint32 week;
        uint32 day;
    }

    struct EmissionId {
        uint16 debt;
        uint16 minting;
    }

    // Store the necessary data for a trove
    struct Trove {
        uint256 debt;
        uint256 coll;
        uint256 stake;
        Status status;
        uint128 arrayIndex;
        uint256 activeInterestIndex;
    }

    struct RedemptionTotals {
        uint256 remainingDebt;
        uint256 totalDebtToRedeem;
        uint256 totalCollateralDrawn;
        uint256 collateralFee;
        uint256 collateralToSendToRedeemer;
        uint256 decayedBaseRate;
        uint256 price;
        uint256 totalDebtSupplyAtStart;
    }

    struct SingleRedemptionValues {
        uint256 debtLot;
        uint256 collateralLot;
        bool cancelledPartial;
    }

    // Object containing the collateral and debt snapshots for a given active trove
    struct RewardSnapshot {
        uint256 collateral;
        uint256 debt;
    }

    modifier whenNotPaused() {
        require(!paused, "Collateral Paused");
        _;
    }

    constructor(
        address _bimaCore,
        address _gasPoolAddress,
        address _debtTokenAddress,
        address _borrowerOperationsAddress,
        address _vault,
        address _liquidationManager,
        uint256 _gasCompensation,
        TokenWrapperFactory _tokenWrapperFactory
    ) BimaOwnable(_bimaCore) BimaBase(_gasCompensation) SystemStart(_bimaCore) {
        gasPoolAddress = _gasPoolAddress;
        debtToken = IDebtToken(_debtTokenAddress);
        borrowerOperationsAddress = _borrowerOperationsAddress;
        vault = IBimaVault(_vault);
        liquidationManager = _liquidationManager;
        tokenWrapperFactory = _tokenWrapperFactory;
    }

    function setAddresses(address _priceFeedAddress, address _sortedTrovesAddress, address _collateralToken) external {
        // Factory::deployNewInstance calls this once when new TroveManager
        // deployed so even without access control it can't be called again
        require(address(sortedTroves) == address(0), "TroveManager: Addresses already set");

        priceFeed = IPriceFeed(_priceFeedAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        collateralToken = IERC20(_collateralToken);

        systemDeploymentTime = block.timestamp;
        sunsetting = false;
        activeInterestIndex = INTEREST_PRECISION;
        lastActiveIndexUpdate = block.timestamp;
    }

    function notifyRegisteredId(uint256[] calldata _assignedIds) external returns (bool success) {
        // called by BimaVault when the TroveManager is registered
        // as an emissions receiver
        require(msg.sender == address(vault), "!vault");

        // prevent vault from calling this multiple times
        require(emissionId.debt == 0, "Already assigned");

        // enforce that both debt & mint ids have been provided
        require(_assignedIds.length == 2, "Incorrect ID count");

        emissionId = EmissionId({
            debt: SafeCast.toUint16(_assignedIds[0]),
            minting: SafeCast.toUint16(_assignedIds[1])
        });

        periodFinish = uint32(((block.timestamp / 1 weeks) + 1) * 1 weeks);

        success = true;
    }

    /**
     * @notice Sets the pause state for this trove manager
     *         Pausing is used to mitigate risks in exceptional circumstances
     *         Functionalities affected by pausing are:
     *         - New borrowing is not possible
     *         - New collateral deposits are not possible
     * @param _paused If true the protocol is paused
     */
    function setPaused(bool _paused) external {
        require((_paused && msg.sender == guardian()) || msg.sender == owner(), "Unauthorized");
        paused = _paused;

        if (_paused) {
            emit Paused();
        } else {
            emit Unpaused();
        }
    }

    /**
     * @notice Sets a custom price feed for this trove manager
     * @param _priceFeedAddress Price feed address
     */
    function setPriceFeed(address _priceFeedAddress) external onlyOwner {
        priceFeed = IPriceFeed(_priceFeedAddress);
        emit SetPriceFeed(_priceFeedAddress);
    }

    /**
     * @notice Starts sunsetting a collateral
     *         During sunsetting only the following are possible:
               1) Disable collateral handoff to SP
               2) Greatly Increase interest rate to incentivize redemptions
               3) Remove redemptions fees
               4) Disable new loans
        @dev IMPORTANT: When sunsetting a collateral altogether this function should be called on
                        all TM linked to that collateral as well as `StabilityPool.startCollateralSunset`
     */
    function startSunset() external onlyOwner {
        sunsetting = true;

        // important to call this first before re-setting parameters
        _accrueActiveInterests();

        interestRate = SUNSETTING_INTEREST_RATE;
        // accrual function doesn't update timestamp if interest was 0
        lastActiveIndexUpdate = block.timestamp;
        redemptionFeeFloor = 0;
        maxSystemDebt = 0;

        emit StartSunset();
    }

    /*
        _minuteDecayFactor is calculated as

            10**18 * (1/2)**(1/n)

        where n = the half-life in minutes
     */
    function setParameters(
        uint256 _minuteDecayFactor,
        uint256 _redemptionFeeFloor,
        uint256 _maxRedemptionFee,
        uint256 _borrowingFeeFloor,
        uint256 _maxBorrowingFee,
        uint256 _interestRateInBPS,
        uint256 _maxSystemDebt,
        uint256 _MCR
    ) public {
        // checks without storage reads first - fail fast
        require(_MCR <= CCR && _MCR >= 1.1e18, "MCR cannot be > CCR or < 110%");

        require(_interestRateInBPS <= MAX_INTEREST_RATE_IN_BPS, "Interest > Maximum");

        require(
            _minuteDecayFactor >= 977159968434245000 && // half-life of 30 minutes
                _minuteDecayFactor <= 999931237762985000, // half-life of 1 week
            "_minuteDecayFactor out of range"
        );
        require(
            _redemptionFeeFloor <= _maxRedemptionFee && _maxRedemptionFee <= BIMA_DECIMAL_PRECISION,
            "Redemption fees out of range"
        );
        require(
            _borrowingFeeFloor <= _maxBorrowingFee && _maxBorrowingFee <= BIMA_DECIMAL_PRECISION,
            "Borrowing fees out of range"
        );

        // checks with storage reads next
        require(!sunsetting, "Cannot change after sunset");

        // Factory::deployNewInstance calls this once when new TroveManager
        // deployed so even without access control it can't be called again
        // by anyone else apart from the owner
        if (minuteDecayFactor != 0) {
            require(msg.sender == owner(), "Only owner");
        }

        _decayBaseRate();

        minuteDecayFactor = _minuteDecayFactor;
        redemptionFeeFloor = _redemptionFeeFloor;
        maxRedemptionFee = _maxRedemptionFee;
        borrowingFeeFloor = _borrowingFeeFloor;
        maxBorrowingFee = _maxBorrowingFee;
        maxSystemDebt = _maxSystemDebt;

        // calculate interest rate using input bps
        uint256 newInterestRate = (INTEREST_PRECISION * _interestRateInBPS) / (BIMA_100_PCT * SECONDS_IN_YEAR);

        // if rate is changing, accrue interest under the old rate first
        // before updating to the new interest rate
        if (newInterestRate != interestRate) {
            _accrueActiveInterests();
            // accrual function doesn't update timestamp if interest was 0
            lastActiveIndexUpdate = block.timestamp;
            interestRate = newInterestRate;
        }

        MCR = _MCR;

        emit SetParameters(
            _minuteDecayFactor,
            _redemptionFeeFloor,
            _maxRedemptionFee,
            _borrowingFeeFloor,
            _maxBorrowingFee,
            _interestRateInBPS,
            _maxSystemDebt,
            _MCR
        );
    }

    function collectInterests() external {
        // checks
        uint256 interestPayableCached = interestPayable;
        require(interestPayableCached > 0, "Nothing to collect");

        // effects
        interestPayable = 0;
        emit CollectedInterest(interestPayableCached);

        // interactions
        debtToken.mint(BIMA_CORE.feeReceiver(), interestPayableCached);
    }

    // --- Getters ---

    function fetchPrice() public returns (uint256 price) {
        IPriceFeed _priceFeed = priceFeed;
        if (address(_priceFeed) == address(0)) {
            _priceFeed = IPriceFeed(BIMA_CORE.priceFeed());
        }
        price = _priceFeed.fetchPrice(address(collateralToken));
    }

    function getWeekAndDay() public view returns (uint256 week, uint256 day) {
        uint256 duration = (block.timestamp - startTime);
        week = duration / 1 weeks;
        day = (duration % 1 weeks) / 1 days;
    }

    function getTotalMints(uint256 week) external view returns (uint32[7] memory mints) {
        mints = totalMints[week];
    }

    function getTroveOwnersCount() external view returns (uint256 count) {
        count = TroveOwners.length;
    }

    function getTroveFromTroveOwnersArray(uint256 _index) external view returns (address owners) {
        owners = TroveOwners[_index];
    }

    function getTroveStatus(address _borrower) external view returns (Status status) {
        status = Troves[_borrower].status;
    }

    function getTroveStake(address _borrower) external view returns (uint256 stake) {
        stake = Troves[_borrower].stake;
    }

    /**
        @notice Get the current total collateral and debt amounts for a trove
        @dev Also includes pending rewards from redistribution
     */
    function getTroveCollAndDebt(address _borrower) public view returns (uint256 coll, uint256 debt) {
        (debt, coll, , ) = getEntireDebtAndColl(_borrower);
    }

    /**
        @notice Get the total and pending collateral and debt amounts for a trove
        @dev Used by the liquidation manager
     */
    function getEntireDebtAndColl(
        address _borrower
    ) public view returns (uint256 debt, uint256 coll, uint256 pendingDebtReward, uint256 pendingCollateralReward) {
        Trove storage t = Troves[_borrower];
        debt = t.debt;
        coll = t.coll;

        (pendingCollateralReward, pendingDebtReward) = getPendingCollAndDebtRewards(_borrower);

        // Accrued trove interest for correct liquidation values. This assumes the index to be updated.
        uint256 troveInterestIndex = t.activeInterestIndex;

        if (troveInterestIndex > 0) {
            (uint256 currentIndex, ) = _calculateInterestIndex();
            debt = (debt * currentIndex) / troveInterestIndex;
        }

        debt += pendingDebtReward;
        coll += pendingCollateralReward;
    }

    // includes defaulted collateral
    function getEntireSystemColl() public view returns (uint256 coll) {
        coll = totalActiveCollateral + defaultedCollateral;
    }

    // includes defaulted debt
    function getEntireSystemDebt() public view returns (uint256 debt) {
        debt = totalActiveDebt;

        (, uint256 interestFactor) = _calculateInterestIndex();
        if (interestFactor > 0) {
            debt += Math.mulDiv(debt, interestFactor, INTEREST_PRECISION);
        }

        debt += defaultedDebt;
    }

    function getEntireSystemBalances() external returns (uint256 coll, uint256 debt, uint256 price) {
        coll = getEntireSystemColl();
        debt = getEntireSystemDebt();
        price = fetchPrice();
    }

    // --- Helper functions ---

    // Return the nominal collateral ratio (ICR) of a given Trove, without the price. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getNominalICR(address _borrower) public view returns (uint256 NICR) {
        (uint256 currentCollateral, uint256 currentDebt) = getTroveCollAndDebt(_borrower);

        NICR = BimaMath._computeNominalCR(currentCollateral, currentDebt);
    }

    // Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(address _borrower, uint256 _price) public view returns (uint256 ICR) {
        (uint256 currentCollateral, uint256 currentDebt) = getTroveCollAndDebt(_borrower);

        ICR = BimaMath._computeCR(currentCollateral, currentDebt, _price);
    }

    // excludes defaulted collateral
    function getTotalActiveCollateral() public view returns (uint256 currentActiveCollateral) {
        currentActiveCollateral = totalActiveCollateral;
    }

    // excludes defaulted debt
    function getTotalActiveDebt() public view returns (uint256 currentActiveDebt) {
        currentActiveDebt = totalActiveDebt;

        (, uint256 interestFactor) = _calculateInterestIndex();
        if (interestFactor > 0) {
            currentActiveDebt += Math.mulDiv(currentActiveDebt, interestFactor, INTEREST_PRECISION);
        }
    }

    // Get the borrower's pending accumulated collateral and debt rewards, earned by their stake
    function getPendingCollAndDebtRewards(
        address _borrower
    ) public view returns (uint256 pendingColl, uint256 pendingDebt) {
        RewardSnapshot memory snapshot = rewardSnapshots[_borrower];

        uint256 coll = L_collateral - snapshot.collateral;
        uint256 debt = L_debt - snapshot.debt;

        if (coll + debt == 0 || Troves[_borrower].status != Status.active) return (0, 0);

        uint256 stake = Troves[_borrower].stake;

        pendingColl = (stake * coll) / BIMA_DECIMAL_PRECISION;
        pendingDebt = (stake * debt) / BIMA_DECIMAL_PRECISION;
    }

    function hasPendingRewards(address _borrower) public view returns (bool output) {
        /*
         * A Trove has pending rewards if its snapshot is less than the current rewards per-unit-staked sum:
         * this indicates that rewards have occured since the snapshot was made, and the user therefore has
         * pending rewards
         */
        if (Troves[_borrower].status == Status.active) {
            output = (rewardSnapshots[_borrower].collateral < L_collateral);
        }
    }

    // --- Redemption fee functions ---

    /*
     * This function has two impacts on the baseRate state variable:
     * 1) decays the baseRate based on time passed since last redemption or debt borrowing operation.
     * then,
     * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
     */
    function _updateBaseRateFromRedemption(
        uint256 _collateralDrawn,
        uint256 _price,
        uint256 _totalDebtSupply
    ) internal returns (uint256 newBaseRate) {
        uint256 decayedBaseRate = _calcDecayedBaseRate();

        /* Convert the drawn collateral back to debt at face value rate (1 debt:1 USD), in order to get
         * the fraction of total supply that was redeemed at face value. */
        uint256 redeemedDebtFraction = (_collateralDrawn * _price) / _totalDebtSupply;

        newBaseRate = decayedBaseRate + (redeemedDebtFraction / BETA);
        newBaseRate = BimaMath._min(newBaseRate, BIMA_DECIMAL_PRECISION); // cap baseRate at a maximum of 100%

        // Update the baseRate state variable
        baseRate = newBaseRate;
        emit BaseRateUpdated(newBaseRate);

        _updateLastFeeOpTime();
    }

    function getRedemptionRate() public view returns (uint256 rate) {
        rate = _calcRedemptionRate(baseRate);
    }

    function getRedemptionRateWithDecay() public view returns (uint256 rateWithDecay) {
        rateWithDecay = _calcRedemptionRate(_calcDecayedBaseRate());
    }

    function _calcRedemptionRate(uint256 _baseRate) internal view returns (uint256 rate) {
        rate = BimaMath._min(
            redemptionFeeFloor + _baseRate,
            maxRedemptionFee // cap at a maximum of 100%
        );
    }

    function getRedemptionFeeWithDecay(uint256 _collateralDrawn) external view returns (uint256 feeWithDecay) {
        feeWithDecay = _calcRedemptionFee(getRedemptionRateWithDecay(), _collateralDrawn);
    }

    function _calcRedemptionFee(
        uint256 _redemptionRate,
        uint256 _collateralDrawn
    ) internal pure returns (uint256 redemptionFee) {
        redemptionFee = (_redemptionRate * _collateralDrawn) / BIMA_DECIMAL_PRECISION;
        require(redemptionFee < _collateralDrawn, "Fee exceeds returned collateral");
    }

    // --- Borrowing fee functions ---

    function getBorrowingRate() public view returns (uint256 rate) {
        rate = _calcBorrowingRate(baseRate);
    }

    function getBorrowingRateWithDecay() public view returns (uint256 rateWithDecay) {
        rateWithDecay = _calcBorrowingRate(_calcDecayedBaseRate());
    }

    function _calcBorrowingRate(uint256 _baseRate) internal view returns (uint256 rate) {
        rate = BimaMath._min(borrowingFeeFloor + _baseRate, maxBorrowingFee);
    }

    function getBorrowingFee(uint256 _debt) external view returns (uint256 fee) {
        fee = _calcBorrowingFee(getBorrowingRate(), _debt);
    }

    function getBorrowingFeeWithDecay(uint256 _debt) external view returns (uint256 feeWithDecay) {
        feeWithDecay = _calcBorrowingFee(getBorrowingRateWithDecay(), _debt);
    }

    function _calcBorrowingFee(uint256 _borrowingRate, uint256 _debt) internal pure returns (uint256 fee) {
        fee = (_borrowingRate * _debt) / BIMA_DECIMAL_PRECISION;
    }

    // --- Internal fee functions ---

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime() internal {
        uint256 timePassed = block.timestamp - lastFeeOperationTime;

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            uint256 minutesPassed = timePassed / SECONDS_IN_ONE_MINUTE;

            lastFeeOperationTime += minutesPassed * SECONDS_IN_ONE_MINUTE;
            emit LastFeeOpTimeUpdated(block.timestamp);
        }
    }

    function _calcDecayedBaseRate() internal view returns (uint256 rate) {
        uint256 minutesPassed = (block.timestamp - lastFeeOperationTime) / SECONDS_IN_ONE_MINUTE;
        uint256 decayFactor = BimaMath._decPow(minuteDecayFactor, minutesPassed);

        rate = (baseRate * decayFactor) / BIMA_DECIMAL_PRECISION;
    }

    // --- Redemption functions ---

    /* Send _debtAmount debt to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
     * request.  Applies pending rewards to a Trove before reducing its debt and coll.
     *
     * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
     * splitting the total _amount in appropriate chunks and calling the function multiple times.
     *
     * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
     * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
     * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
     * costs can vary.
     *
     * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
     * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
     * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
     * in the sortedTroves list along with the ICR value that the hint was found for.
     *
     * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
     * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
     * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining debt amount, which they can attempt
     * to redeem later.
     */
    function redeemCollateral(
        uint256 _debtAmount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR,
        uint256 _maxIterations,
        uint256 _maxFeePercentage
    ) external {
        // checks without storage reads first - fail fast
        require(_debtAmount > 0, "Amount must be greater than zero");

        // checks with storage reads next
        require(debtToken.balanceOf(msg.sender) >= _debtAmount, "Insufficient balance");
        require(block.timestamp >= systemDeploymentTime + BOOTSTRAP_PERIOD, "BOOTSTRAP_PERIOD");
        uint256 _MCR = MCR;
        require(IBorrowerOperations(borrowerOperationsAddress).getTCR() >= _MCR, "Cannot redeem when TCR < MCR");
        require(
            _maxFeePercentage >= redemptionFeeFloor && _maxFeePercentage <= maxRedemptionFee,
            "Max fee 0.5% to 100%"
        );

        ISortedTroves _sortedTrovesCached = sortedTroves;

        RedemptionTotals memory totals;
        totals.price = fetchPrice();

        _updateBalances();
        totals.totalDebtSupplyAtStart = getEntireSystemDebt();

        totals.remainingDebt = _debtAmount;
        address currentBorrower;

        if (_isValidFirstRedemptionHint(_sortedTrovesCached, _firstRedemptionHint, totals.price, _MCR)) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = _sortedTrovesCached.getLast();
            // Find the first trove with ICR >= MCR
            while (currentBorrower != address(0) && getCurrentICR(currentBorrower, totals.price) < _MCR) {
                currentBorrower = _sortedTrovesCached.getPrev(currentBorrower);
            }
        }

        // Loop through the Troves starting from the one with lowest collateral ratio until _amount of debt is exchanged for collateral
        if (_maxIterations == 0) {
            _maxIterations = type(uint256).max;
        }
        while (currentBorrower != address(0) && totals.remainingDebt > 0 && _maxIterations > 0) {
            _maxIterations--;
            // Save the address of the Trove preceding the current one, before potentially modifying the list
            address nextUserToCheck = _sortedTrovesCached.getPrev(currentBorrower);

            _applyPendingRewards(currentBorrower);
            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
                _sortedTrovesCached,
                currentBorrower,
                totals.remainingDebt,
                totals.price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum)
            // therefore we could not redeem from the last Trove
            if (singleRedemption.cancelledPartial) break;

            totals.totalDebtToRedeem += singleRedemption.debtLot;
            totals.totalCollateralDrawn += singleRedemption.collateralLot;

            totals.remainingDebt -= singleRedemption.debtLot;
            currentBorrower = nextUserToCheck;
        }

        require(totals.totalCollateralDrawn > 0, "Unable to redeem any amount");

        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // Use the saved total debt supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(totals.totalCollateralDrawn, totals.price, totals.totalDebtSupplyAtStart);

        // Calculate the collateral fee
        totals.collateralFee = sunsetting ? 0 : _calcRedemptionFee(getRedemptionRate(), totals.totalCollateralDrawn);

        _requireUserAcceptsFee(totals.collateralFee, totals.totalCollateralDrawn, _maxFeePercentage);

        _sendCollateral(BIMA_CORE.feeReceiver(), totals.collateralFee);

        totals.collateralToSendToRedeemer = totals.totalCollateralDrawn - totals.collateralFee;

        emit Redemption(_debtAmount, totals.totalDebtToRedeem, totals.totalCollateralDrawn, totals.collateralFee);

        // Burn the total debt that is cancelled
        debtToken.burn(msg.sender, totals.totalDebtToRedeem);

        // Update Trove Manager debt, and send collateral to account
        totalActiveDebt -= totals.totalDebtToRedeem;
        _sendCollateral(msg.sender, totals.collateralToSendToRedeemer);

        _resetState();
    }

    // Redeem as much collateral as possible from _borrower's Trove in exchange for debt up to _maxDebtAmount
    function _redeemCollateralFromTrove(
        ISortedTroves _sortedTrovesCached,
        address _borrower,
        uint256 _maxDebtAmount,
        uint256 _price,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint256 _partialRedemptionHintNICR
    ) internal returns (SingleRedemptionValues memory singleRedemption) {
        Trove storage t = Troves[_borrower];
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
        singleRedemption.debtLot = BimaMath._min(_maxDebtAmount, t.debt - DEBT_GAS_COMPENSATION);

        // Get the CollateralLot of equivalent value in USD
        singleRedemption.collateralLot = (singleRedemption.debtLot * BIMA_DECIMAL_PRECISION) / _price;

        // Decrease the debt and collateral of the current Trove according to the debt lot and corresponding collateral to send
        uint256 newDebt = (t.debt) - singleRedemption.debtLot;
        uint256 newColl = (t.coll) - singleRedemption.collateralLot;

        if (newDebt == DEBT_GAS_COMPENSATION) {
            // No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
            _closeTrove(_borrower, Status.closedByRedemption);
            _redeemCloseTrove(_borrower, DEBT_GAS_COMPENSATION, newColl);
            emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.redeemCollateral);
        } else {
            uint256 newNICR = BimaMath._computeNominalCR(newColl, newDebt);
            /*
             * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
             * certainly result in running out of gas.
             *
             * If the resultant net debt of the partial is less than the minimum, net debt we bail
             *
             * If the debt amount was small causing a rounding down to zero precision loss
             * in the received collateral calculation, we bail
             */

            {
                // We check if the ICR hint is reasonable up to date, with continuous interest there might be slight differences (<1bps)
                uint256 icrError = _partialRedemptionHintNICR > newNICR
                    ? _partialRedemptionHintNICR - newNICR
                    : newNICR - _partialRedemptionHintNICR;
                if (
                    icrError > 5e14 ||
                    singleRedemption.collateralLot == 0 ||
                    _getNetDebt(newDebt) < IBorrowerOperations(borrowerOperationsAddress).minNetDebt()
                ) {
                    singleRedemption.cancelledPartial = true;
                    return singleRedemption;
                }
            }

            _sortedTrovesCached.reInsert(_borrower, newNICR, _upperPartialRedemptionHint, _lowerPartialRedemptionHint);

            t.debt = newDebt;
            t.coll = newColl;
            _updateStakeAndTotalStakes(t);

            emit TroveUpdated(_borrower, newDebt, newColl, t.stake, TroveManagerOperation.redeemCollateral);
        }
    }

    /*
     * Called when a full redemption occurs, and closes the trove.
     * The redeemer swaps (debt - liquidation reserve) debt for (debt - liquidation reserve) worth of collateral, so the debt liquidation reserve left corresponds to the remaining debt.
     * In order to close the trove, the debt liquidation reserve is burned, and the corresponding debt is removed.
     * The debt recorded on the trove's struct is zero'd elswhere, in _closeTrove.
     * Any surplus collateral left in the trove can be later claimed by the borrower.
     */
    function _redeemCloseTrove(address _borrower, uint256 _debt, uint256 _collateral) internal {
        debtToken.burn(gasPoolAddress, _debt);
        totalActiveDebt -= _debt;

        surplusBalances[_borrower] += _collateral;
        totalActiveCollateral -= _collateral;
    }

    function _isValidFirstRedemptionHint(
        ISortedTroves _sortedTroves,
        address _firstRedemptionHint,
        uint256 _price,
        uint256 _MCR
    ) internal view returns (bool isValid) {
        if (
            _firstRedemptionHint == address(0) ||
            !_sortedTroves.contains(_firstRedemptionHint) ||
            getCurrentICR(_firstRedemptionHint, _price) < _MCR
        ) {
            return false;
        }

        address nextTrove = _sortedTroves.getNext(_firstRedemptionHint);
        isValid = nextTrove == address(0) || getCurrentICR(nextTrove, _price) < _MCR;
    }

    /**
     * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
     */
    function claimCollateral(address _receiver) external {
        uint256 claimableColl = surplusBalances[msg.sender];
        require(claimableColl > 0, "No collateral available to claim");

        surplusBalances[msg.sender] = 0;

        uint256 unwrappedAmount = _getWrapper().unwrap(claimableColl);

        collateralToken.safeTransfer(_receiver, unwrappedAmount);
    }

    // --- Reward Claim functions ---

    function claimReward(address receiver) external returns (uint256 amount) {
        amount = _claimReward(msg.sender);

        if (amount > 0) {
            vault.transferAllocatedTokens(msg.sender, receiver, amount);
        }
        emit RewardClaimed(msg.sender, receiver, amount);
    }

    function vaultClaimReward(address claimant, address) external returns (uint256 amount) {
        require(msg.sender == address(vault), "!vault");

        amount = _claimReward(claimant);
    }

    function _claimReward(address account) internal returns (uint256 amount) {
        require(emissionId.debt > 0, "Rewards not active");
        // update active debt rewards
        _applyPendingRewards(account);
        amount = storedPendingReward[account];
        if (amount > 0) storedPendingReward[account] = 0;

        // add pending mint awards
        uint256 mintAmount = _getPendingMintReward(account);
        if (mintAmount > 0) {
            amount += mintAmount;
            delete accountLatestMint[account];
        }
    }

    function claimableReward(address account) external view returns (uint256 amount) {
        // previously calculated rewards
        amount = storedPendingReward[account];

        // pending active debt rewards
        uint256 updated = periodFinish;
        if (updated > block.timestamp) updated = block.timestamp;
        uint256 duration = updated - lastUpdate;
        uint256 integral = rewardIntegral;
        if (duration > 0) {
            uint256 supply = totalActiveDebt;
            if (supply > 0) {
                integral += (duration * rewardRate * 1e18) / supply;
            }
        }
        uint256 integralFor = rewardIntegralFor[account];

        if (integral > integralFor) {
            amount += (Troves[account].debt * (integral - integralFor)) / 1e18;
        }

        // pending mint rewards
        amount += _getPendingMintReward(account);
    }

    function _getPendingMintReward(address account) internal view returns (uint256 reward) {
        VolumeData memory data = accountLatestMint[account];
        if (data.amount > 0) {
            (uint256 week, uint256 day) = getWeekAndDay();
            if (data.day != day || data.week != week) {
                reward = (dailyMintReward[data.week] * data.amount) / totalMints[data.week][data.day];
            }
        }
    }

    function _updateIntegrals(address account, uint256 balance, uint256 supply) internal {
        uint256 integral = _updateRewardIntegral(supply);
        _updateIntegralForAccount(account, balance, integral);
    }

    function _updateIntegralForAccount(address account, uint256 balance, uint256 currentIntegral) internal {
        uint256 integralFor = rewardIntegralFor[account];

        if (currentIntegral > integralFor) {
            storedPendingReward[account] += (balance * (currentIntegral - integralFor)) / 1e18;
            rewardIntegralFor[account] = currentIntegral;
        }
    }

    function _updateRewardIntegral(uint256 supply) internal returns (uint256 integral) {
        uint256 _periodFinish = periodFinish;
        uint256 updated = _periodFinish;
        if (updated > block.timestamp) updated = block.timestamp;
        uint256 duration = updated - lastUpdate;
        integral = rewardIntegral;
        if (duration > 0) {
            lastUpdate = uint32(updated);
            if (supply > 0) {
                integral += (duration * rewardRate * 1e18) / supply;
                rewardIntegral = integral;
            }
        }
        _fetchRewards(_periodFinish);
    }

    function _fetchRewards(uint256 _periodFinish) internal {
        EmissionId memory id = emissionId;
        if (id.debt == 0) return;
        uint256 currentWeek = getWeek();
        if (currentWeek < (_periodFinish - startTime) / 1 weeks) return;
        uint256 previousWeek = (_periodFinish - startTime) / 1 weeks - 1;

        // active debt rewards
        uint256 amount = vault.allocateNewEmissions(id.debt);
        if (block.timestamp < _periodFinish) {
            uint256 remaining = _periodFinish - block.timestamp;
            amount += remaining * rewardRate;
        }
        rewardRate = SafeCast.toUint128(amount / BIMA_REWARD_DURATION);
        lastUpdate = uint32(block.timestamp);
        periodFinish = uint32(block.timestamp + BIMA_REWARD_DURATION);

        // minting rewards
        amount = vault.allocateNewEmissions(id.minting);
        uint256 reward = dailyMintReward[previousWeek];
        if (reward > 0) {
            uint32[7] memory totals = totalMints[previousWeek];
            for (uint256 i; i < 7; i++) {
                if (totals[i] == 0) {
                    amount += reward;
                }
            }
        }
        dailyMintReward[currentWeek] = amount / 7;
    }

    // --- Trove Adjustment functions ---

    function openTrove(
        address _borrower,
        uint256 _collateralAmount,
        uint256 _collateralWrappedAmount,
        uint256 _compositeDebt,
        uint256 NICR,
        address _upperHint,
        address _lowerHint,
        bool _isRecoveryMode
    ) external whenNotPaused returns (uint256 stake, uint256 arrayIndex) {
        // only BorrowerOperations can open new Trove
        _requireCallerIsBO();

        // not when sunsetting
        require(!sunsetting, "Cannot open while sunsetting");

        // borrower can only have 1 Trove active with each TroveManager
        Trove storage t = Troves[_borrower];
        require(t.status != Status.active, "BorrowerOps: Trove is active");

        // cache total active debt
        uint256 totalActiveDebtPre = totalActiveDebt;

        // update storage - borrower Trove state
        t.status = Status.active;
        t.coll = _collateralWrappedAmount;
        t.debt = _compositeDebt;
        t.activeInterestIndex = _accrueActiveInterests();

        _updateTroveRewardSnapshots(_borrower);

        // this updates t.stake
        stake = _updateStakeAndTotalStakes(t);

        sortedTroves.insert(_borrower, NICR, _upperHint, _lowerHint);

        // add borrower to list of active Trove owners
        TroveOwners.push(_borrower);
        arrayIndex = TroveOwners.length - 1;
        t.arrayIndex = uint128(arrayIndex);

        _updateIntegrals(_borrower, 0, totalActiveDebtPre);
        if (!_isRecoveryMode) _updateMintVolume(_borrower, _compositeDebt);

        totalActiveCollateral += _collateralWrappedAmount;

        // enforce collateral debt limit
        uint256 _newTotalDebt = totalActiveDebtPre + _compositeDebt;
        require(_newTotalDebt + defaultedDebt <= maxSystemDebt, "Collateral debt limit reached");

        // update storage new total active debt
        totalActiveDebt = _newTotalDebt;

        collateralToken.approve(address(_getWrapper()), _collateralAmount);
        _getWrapper().wrap(_collateralAmount);
    }

    function updateTroveFromAdjustment(
        bool _isRecoveryMode,
        bool _isDebtIncrease,
        uint256 _debtChange,
        uint256 _netDebtChange,
        bool _isCollIncrease,
        uint256 _collChange,
        uint256 _collChangeWrapped,
        address _upperHint,
        address _lowerHint,
        address _borrower,
        address _receiver
    ) external returns (uint256 newColl, uint256 newDebt, uint256 newStake) {
        _requireCallerIsBO();

        if (_isCollIncrease || _isDebtIncrease) {
            require(!paused, "Collateral Paused");
            require(!sunsetting, "Cannot increase while sunsetting");
        }

        Trove storage t = Troves[_borrower];
        require(t.status == Status.active, "Trove closed or does not exist");

        // output borrower current debt from storage
        newDebt = t.debt;

        // if debt is changing, increase or decrease as required
        if (_debtChange > 0) {
            if (_isDebtIncrease) {
                newDebt += _netDebtChange;

                if (!_isRecoveryMode) _updateMintVolume(_borrower, _netDebtChange);
                _increaseDebt(_receiver, _netDebtChange, _debtChange);
            } else {
                newDebt -= _netDebtChange;
                _decreaseDebt(_receiver, _debtChange);
            }

            // update borrower storage with new debt value
            t.debt = newDebt;
        }

        // output borrower current collateral from storage
        newColl = t.coll;

        // if collateral is changing, increase or decrease as required
        if (_collChange > 0) {
            if (_isCollIncrease) {
                newColl += _collChangeWrapped;
                totalActiveCollateral += _collChangeWrapped;

                collateralToken.approve(address(_getWrapper()), _collChange);
                _getWrapper().wrap(_collChange);
                // trust that BorrowerOperations sent the collateral
            } else {
                newColl -= _collChangeWrapped;
                _sendCollateral(_receiver, _collChangeWrapped);
            }

            // update borrower storage with new collateral value
            t.coll = newColl;
        }

        uint256 newNICR = BimaMath._computeNominalCR(newColl, newDebt);
        sortedTroves.reInsert(_borrower, newNICR, _upperHint, _lowerHint);

        newStake = _updateStakeAndTotalStakes(t);
    }

    function closeTrove(address _borrower, address _receiver, uint256 collAmount, uint256 debtAmount) external {
        // only BorrowerOperations can close an active Trove
        _requireCallerIsBO();
        require(Troves[_borrower].status == Status.active, "Trove closed or does not exist");

        _closeTrove(_borrower, Status.closedByOwner);

        totalActiveDebt -= debtAmount;

        _sendCollateral(_receiver, collAmount);
        _resetState();
    }

    /**
        @dev Only called from `closeTrove` because liquidating the final trove is blocked in
             `LiquidationManager`. Many liquidation paths involve redistributing debt and
             collateral to existing troves. If the collateral is being sunset, the final trove
             must be closed by repaying the debt or via a redemption.
     */
    function _resetState() private {
        if (TroveOwners.length == 0) {
            activeInterestIndex = INTEREST_PRECISION;
            lastActiveIndexUpdate = block.timestamp;
            totalStakes = 0;
            totalStakesSnapshot = 0;
            totalCollateralSnapshot = 0;
            L_collateral = 0;
            L_debt = 0;
            lastCollateralError_Redistribution = 0;
            lastDebtError_Redistribution = 0;
            totalActiveCollateral = 0;
            totalActiveDebt = 0;
            defaultedCollateral = 0;
            defaultedDebt = 0;
        }
    }

    function _closeTrove(address _borrower, Status closedStatus) internal {
        uint256 TroveOwnersArrayLength = TroveOwners.length;

        // update storage - borrower Trove state
        Trove storage t = Troves[_borrower];
        t.status = closedStatus;
        t.coll = 0;
        t.debt = 0;
        t.activeInterestIndex = 0;
        // _removeStake functionality
        totalStakes -= t.stake;
        t.stake = 0;

        ISortedTroves sortedTrovesCached = sortedTroves;
        rewardSnapshots[_borrower].collateral = 0;
        rewardSnapshots[_borrower].debt = 0;

        if (TroveOwnersArrayLength > 1 && sortedTrovesCached.getSize() > 1) {
            // remove trove owner from the TroveOwners array, not preserving array order
            uint128 index = t.arrayIndex;
            address addressToMove = TroveOwners[TroveOwnersArrayLength - 1];
            TroveOwners[index] = addressToMove;
            Troves[addressToMove].arrayIndex = index;
            emit TroveIndexUpdated(addressToMove, index);
        }

        TroveOwners.pop();

        sortedTrovesCached.remove(_borrower);
        t.arrayIndex = 0;
    }

    function _updateMintVolume(address account, uint256 initialAmount) internal {
        uint32 amount = SafeCast.toUint32(initialAmount / VOLUME_MULTIPLIER);
        (uint256 week, uint256 day) = getWeekAndDay();
        totalMints[week][day] += amount;

        VolumeData memory data = accountLatestMint[account];
        if (data.day == day && data.week == week) {
            // if the caller made a previous redemption today, we only increase their redeemed amount
            accountLatestMint[account].amount = data.amount + amount;
        } else {
            if (data.amount > 0) {
                // if the caller made a previous redemption on a different day,
                // calculate the emissions earned for that redemption
                uint256 pending = (dailyMintReward[data.week] * data.amount) / totalMints[data.week][data.day];
                storedPendingReward[account] += pending;
            }
            accountLatestMint[account] = VolumeData({week: uint32(week), day: uint32(day), amount: amount});
        }
    }

    // Updates the baseRate state variable based on time elapsed since the last redemption or debt borrowing operation.
    function decayBaseRateAndGetBorrowingFee(uint256 _debt) external returns (uint256 fee) {
        _requireCallerIsBO();
        uint256 rate = _decayBaseRate();

        fee = _calcBorrowingFee(_calcBorrowingRate(rate), _debt);
    }

    function _decayBaseRate() internal returns (uint256 decayedBaseRate) {
        decayedBaseRate = _calcDecayedBaseRate();

        baseRate = decayedBaseRate;
        emit BaseRateUpdated(decayedBaseRate);

        _updateLastFeeOpTime();
    }

    function applyPendingRewards(address _borrower) external returns (uint256 coll, uint256 debt) {
        _requireCallerIsBO();
        (coll, debt) = _applyPendingRewards(_borrower);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
    function _applyPendingRewards(address _borrower) internal returns (uint256 coll, uint256 debt) {
        Trove storage t = Troves[_borrower];

        if (t.status == Status.active) {
            uint256 troveInterestIndex = t.activeInterestIndex;
            uint256 supply = totalActiveDebt;
            uint256 currentInterestIndex = _accrueActiveInterests();
            debt = t.debt;
            uint256 prevDebt = debt;
            coll = t.coll;

            // We accrued interests for this trove if not already updated
            if (troveInterestIndex < currentInterestIndex) {
                debt = (debt * currentInterestIndex) / troveInterestIndex;
                t.activeInterestIndex = currentInterestIndex;
            }

            if (rewardSnapshots[_borrower].collateral < L_collateral) {
                // Compute pending rewards
                (uint256 pendingCollateralReward, uint256 pendingDebtReward) = getPendingCollAndDebtRewards(_borrower);

                // Apply pending rewards to trove's state
                coll += pendingCollateralReward;
                t.coll = coll;
                debt += pendingDebtReward;

                _updateTroveRewardSnapshots(_borrower);

                _movePendingTroveRewardsToActiveBalance(pendingDebtReward, pendingCollateralReward);

                emit TroveUpdated(_borrower, debt, coll, t.stake, TroveManagerOperation.applyPendingRewards);
            }
            if (prevDebt != debt) {
                t.debt = debt;
            }
            _updateIntegrals(_borrower, prevDebt, supply);
        }
    }

    function _updateTroveRewardSnapshots(address _borrower) internal {
        uint256 L_collateralCached = L_collateral;
        uint256 L_debtCached = L_debt;
        rewardSnapshots[_borrower] = RewardSnapshot(L_collateralCached, L_debtCached);
        emit TroveSnapshotsUpdated(L_collateralCached, L_debtCached);
    }

    // Update borrower's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(Trove storage t) internal returns (uint256 newStake) {
        newStake = _computeNewStake(t.coll);
        uint256 oldStake = t.stake;
        t.stake = newStake;
        uint256 newTotalStakes = totalStakes - oldStake + newStake;
        totalStakes = newTotalStakes;
        emit TotalStakesUpdated(newTotalStakes);
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(uint256 _coll) internal view returns (uint256 stake) {
        uint256 totalCollateralSnapshotCached = totalCollateralSnapshot;
        if (totalCollateralSnapshotCached == 0) {
            stake = _coll;
        } else {
            /*
             * The following assert() holds true because:
             * - The system always contains >= 1 trove
             * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
             * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
             */
            uint256 totalStakesSnapshotCached = totalStakesSnapshot;
            assert(totalStakesSnapshotCached > 0);
            stake = (_coll * totalStakesSnapshotCached) / totalCollateralSnapshotCached;
        }
    }

    // --- Liquidation Functions ---

    function closeTroveByLiquidation(address _borrower) external {
        _requireCallerIsLM();
        uint256 debtBefore = Troves[_borrower].debt;
        _closeTrove(_borrower, Status.closedByLiquidation);
        _updateIntegralForAccount(_borrower, debtBefore, rewardIntegral);
    }

    function movePendingTroveRewardsToActiveBalances(uint256 _debtRewards, uint256 _collateralRewards) external {
        _requireCallerIsLM();
        _movePendingTroveRewardsToActiveBalance(_debtRewards, _collateralRewards);
    }

    function _movePendingTroveRewardsToActiveBalance(uint256 _debtRewards, uint256 _collateralRewards) internal {
        defaultedDebt -= _debtRewards;
        totalActiveDebt += _debtRewards;
        defaultedCollateral -= _collateralRewards;
        totalActiveCollateral += _collateralRewards;
    }

    function addCollateralSurplus(address borrower, uint256 collSurplus) external {
        _requireCallerIsLM();
        surplusBalances[borrower] += collSurplus;
    }

    function finalizeLiquidation(
        address _liquidator,
        uint256 _debt,
        uint256 _coll,
        uint256 _collSurplus,
        uint256 _debtGasComp,
        uint256 _collGasComp
    ) external {
        _requireCallerIsLM();
        // redistribute debt and collateral
        _redistributeDebtAndColl(_debt, _coll);

        uint256 _activeColl = totalActiveCollateral;
        if (_collSurplus > 0) {
            _activeColl -= _collSurplus;
            totalActiveCollateral = _activeColl;
        }

        // update system snapshos
        totalStakesSnapshot = totalStakes;
        totalCollateralSnapshot = _activeColl - _collGasComp + defaultedCollateral;
        emit SystemSnapshotsUpdated(totalStakesSnapshot, totalCollateralSnapshot);

        // send gas compensation
        debtToken.returnFromPool(gasPoolAddress, _liquidator, _debtGasComp);
        _sendCollateral(_liquidator, _collGasComp);
    }

    function _redistributeDebtAndColl(uint256 _debt, uint256 _coll) internal {
        if (_debt == 0) {
            return;
        }
        /*
         * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
         * error correction, to keep the cumulative error low in the running totals L_collateral and L_debt:
         *
         * 1) Form numerators which compensate for the floor division errors that occurred the last time this
         * function was called.
         * 2) Calculate "per-unit-staked" ratios.
         * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
         * 4) Store these errors for use in the next correction when this function is called.
         * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
         */
        uint256 collateralNumerator = (_coll * BIMA_DECIMAL_PRECISION) + lastCollateralError_Redistribution;
        uint256 debtNumerator = (_debt * BIMA_DECIMAL_PRECISION) + lastDebtError_Redistribution;
        uint256 totalStakesCached = totalStakes;

        // note: liquidation is prevented when there is only 1 Trove so
        // totalStakesCached always > 0, see comment in LiquidationManager::liquidateTroves

        // Get the per-unit-staked terms
        uint256 collateralRewardPerUnitStaked = collateralNumerator / totalStakesCached;
        uint256 debtRewardPerUnitStaked = debtNumerator / totalStakesCached;

        lastCollateralError_Redistribution = collateralNumerator - (collateralRewardPerUnitStaked * totalStakesCached);
        lastDebtError_Redistribution = debtNumerator - (debtRewardPerUnitStaked * totalStakesCached);

        // Add per-unit-staked terms to the running totals
        uint256 new_L_collateral = L_collateral + collateralRewardPerUnitStaked;
        uint256 new_L_debt = L_debt + debtRewardPerUnitStaked;
        L_collateral = new_L_collateral;
        L_debt = new_L_debt;

        emit LTermsUpdated(new_L_collateral, new_L_debt);

        totalActiveDebt -= _debt;
        defaultedDebt += _debt;
        defaultedCollateral += _coll;
        totalActiveCollateral -= _coll;
    }

    // --- Trove property setters ---

    function _sendCollateral(address _account, uint256 _amount) private {
        if (_amount > 0) {
            totalActiveCollateral -= _amount;
            emit CollateralSent(_account, _amount);

            uint256 unwrappedAmount = _getWrapper().unwrap(_amount);

            collateralToken.safeTransfer(_account, unwrappedAmount);
        }
    }

    function _increaseDebt(address account, uint256 netDebtAmount, uint256 debtAmount) internal {
        uint256 _newTotalDebt = totalActiveDebt + netDebtAmount;
        require(_newTotalDebt + defaultedDebt <= maxSystemDebt, "Collateral debt limit reached");
        totalActiveDebt = _newTotalDebt;
        debtToken.mint(account, debtAmount);
    }

    function decreaseDebtAndSendCollateral(address account, uint256 debt, uint256 coll) external {
        _requireCallerIsLM();
        _decreaseDebt(account, debt);
        _sendCollateral(account, coll);
    }

    function _decreaseDebt(address account, uint256 amount) internal {
        debtToken.burn(account, amount);
        totalActiveDebt = totalActiveDebt - amount;
    }

    // --- Balances and interest ---

    function updateBalances() external {
        _requireCallerIsLM();
        _updateBalances();
    }

    function _updateBalances() private {
        _updateRewardIntegral(totalActiveDebt);
        _accrueActiveInterests();
    }

    // This function must be called any time the debt or the interest changes
    function _accrueActiveInterests() internal returns (uint256 currentInterestIndex) {
        uint256 interestFactor;
        (currentInterestIndex, interestFactor) = _calculateInterestIndex();
        if (interestFactor > 0) {
            uint256 currentDebt = totalActiveDebt;
            uint256 activeInterests = Math.mulDiv(currentDebt, interestFactor, INTEREST_PRECISION);
            totalActiveDebt = currentDebt + activeInterests;
            interestPayable += activeInterests;
            activeInterestIndex = currentInterestIndex;
            lastActiveIndexUpdate = block.timestamp;
        }
    }

    function _calculateInterestIndex() internal view returns (uint256 currentInterestIndex, uint256 interestFactor) {
        uint256 lastIndexUpdateCached = lastActiveIndexUpdate;
        // Short circuit if we updated in the current block
        if (lastIndexUpdateCached == block.timestamp) return (activeInterestIndex, 0);
        uint256 currentInterest = interestRate;
        currentInterestIndex = activeInterestIndex; // we need to return this if it's already up to date
        if (currentInterest > 0) {
            /*
             * Calculate the interest accumulated and the new index:
             * We compound the index and increase the debt accordingly
             */
            uint256 deltaT = block.timestamp - lastIndexUpdateCached;
            interestFactor = deltaT * currentInterest;
            currentInterestIndex += Math.mulDiv(currentInterestIndex, interestFactor, INTEREST_PRECISION);
        }
    }

    // --- Requires ---

    function _requireCallerIsBO() internal view {
        require(msg.sender == borrowerOperationsAddress, "Caller not BO");
    }

    function _requireCallerIsLM() internal view {
        require(msg.sender == liquidationManager, "Not Liquidation Manager");
    }

    function _getWrapper() internal view returns (TokenWrapper tokenWrapper) {
        tokenWrapper = tokenWrapperFactory.getWrapper(collateralToken);
    }
}
