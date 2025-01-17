// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// mocks
import {MockOracle} from "../../contracts/mock/MockOracle.sol";
import {StakedBTC} from "../../contracts/mock/StakedBTC.sol";
import {MockVault} from "../../contracts/mock/MockVault.sol";

// interfaces
import {IDebtToken} from "../../contracts/interfaces/IDebtToken.sol";
import {IStabilityPool} from "../../contracts/interfaces/IStabilityPool.sol";
import {IBorrowerOperations} from "../../contracts/interfaces/IBorrowerOperations.sol";
import {ILiquidationManager} from "../../contracts/interfaces/ILiquidationManager.sol";
import {IBimaVault, IRewards, IBoostDelegate} from "../../contracts/interfaces/IVault.sol";
import {IBimaToken} from "../../contracts/interfaces/IBimaToken.sol";
import {IIncentiveVoting} from "../../contracts/interfaces/IIncentiveVoting.sol";
import {ITokenLocker} from "../../contracts/interfaces/ITokenLocker.sol";
import {IEmissionSchedule} from "../../contracts/interfaces/IEmissionSchedule.sol";
import {IBoostCalculator} from "../../contracts/interfaces/IBoostCalculator.sol";

// core
import {BimaCore} from "../../contracts/core/BimaCore.sol";
import {PriceFeed} from "../../contracts/core/PriceFeed.sol";
import {Factory, IFactory} from "../../contracts/core/Factory.sol";
import {LiquidationManager} from "../../contracts/core/LiquidationManager.sol";
import {DebtToken} from "../../contracts/core/DebtToken.sol";
import {BorrowerOperations} from "../../contracts/core/BorrowerOperations.sol";
import {StabilityPool} from "../../contracts/core/StabilityPool.sol";
import {TroveManager} from "../../contracts/core/TroveManager.sol";
import {SortedTroves} from "../../contracts/core/SortedTroves.sol";

// adapters
import {LendingVaultAdapter} from "../../contracts/adapters/LendingVaultAdapter.sol";

// dao
import {FeeReceiver} from "../../contracts/dao/FeeReceiver.sol";
import {InterimAdmin} from "../../contracts/dao/InterimAdmin.sol";
import {TokenLocker} from "../../contracts/dao/TokenLocker.sol";
import {IncentiveVoting} from "../../contracts/dao/IncentiveVoting.sol";
import {BimaToken} from "../../contracts/dao/BimaToken.sol";
import {BimaVault, IEmissionReceiver} from "../../contracts/dao/Vault.sol";
import {EmissionSchedule} from "../../contracts/dao/EmissionSchedule.sol";
import {BoostCalculator} from "../../contracts/dao/BoostCalculator.sol";

// wrappers
import {TokenWrapperFactory, TokenWrapper} from "../../contracts/wrappers/TokenWrapper.sol";

// external
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// foundry
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

struct Users {
    address owner;
    address guardian;
    address user1;
    address user2;
    address user3;
    address gasPool;
}

struct DeployAddresses {
    uint256 nonce;
    address core;
    address priceFeed;
    address feeReceiver;
    address factory;
    address liquidationMgr;
    address debtToken;
    address borrowerOps;
    address stabilityPool;
    address troveMgr;
    address tokenLocker;
    address incentiveVoting;
    address bimaToken;
    address bimaVault;
    address tokenWrapperFactory;
}

contract TestSetup is Test {
    // test helpers
    Users internal users;
    MockOracle mockOracle;
    StakedBTC stakedBTC;
    MockVault mockVault;

    // core contracts
    BimaCore internal bimaCore;
    PriceFeed internal priceFeed;
    Factory internal factory;
    LiquidationManager internal liquidationMgr;
    DebtToken internal debtToken;
    BorrowerOperations internal borrowerOps;
    StabilityPool internal stabilityPool;
    TroveManager internal troveMgr;
    SortedTroves internal sortedTroves;

    // adapter contracts
    LendingVaultAdapter internal lendingVaultAdapter;

    // dao contracts
    FeeReceiver internal feeReceiver;
    InterimAdmin internal interimAdmin;
    TokenLocker internal tokenLocker;
    IncentiveVoting internal incentiveVoting;
    BimaToken internal bimaToken;
    BimaVault internal bimaVault;
    EmissionSchedule internal emissionSchedule;
    BoostCalculator internal boostCalc;

    // wrapper contracts
    TokenWrapperFactory internal tokenWrapperFactory;

    // constants
    uint256 internal constant INIT_MCR = 2e18; // 200%
    uint256 internal constant INIT_MAX_DEBT = 1_000_000e18; // 1M USD
    uint256 internal constant INIT_REDEMPTION_FEE_FLOOR = 5e15;
    uint256 internal constant INIT_MAX_REDEMPTION_FEE = 1e18;
    uint256 internal constant INIT_BORROWING_FEE_FLOOR = 0;
    uint256 internal constant INIT_MAX_BORROWING_FEE = 0;
    uint256 internal constant INIT_INTEREST_RATE_BPS = 0;

    uint256 internal constant INIT_GAS_COMPENSATION = 1e18;
    uint256 internal constant INIT_MIN_NET_DEBT = 1000e18;
    uint256 internal constant INIT_LOCK_TO_TOKEN_RATIO = 1e18;
    address internal constant ZERO_ADDRESS = address(0);

    uint256 internal constant INIT_BS_GRACE_WEEKS = 5;
    uint64 internal constant INIT_ES_LOCK_WEEKS = 4;
    uint64 internal constant INIT_ES_LOCK_DECAY_WEEKS = 1;
    uint64 internal constant INIT_ES_WEEKLY_PCT = 2500; // 25%
    uint256 internal constant INIT_BAB_TKN_TOTAL_SUPPLY = type(uint32).max * INIT_LOCK_TO_TOKEN_RATIO;
    uint64 internal constant INIT_VLT_LOCK_WEEKS = 2;

    uint256 internal constant MIN_BTC_PRICE_8DEC = 10_000 * 10 ** 8;
    uint256 internal constant MAX_BTC_PRICE_8DEC = 500_000 * 10 ** 8;

    function setUp() public virtual {
        // prevent Foundry from setting block.timestamp = 1 which can cause
        // errors in this protocol
        vm.warp(1659973223);

        // set addresses used by tests
        users.owner = address(0x1111);
        users.guardian = address(0x2222);
        users.user1 = address(0x3333);
        users.user2 = address(0x4444);
        users.gasPool = address(0x5555);
        users.user3 = address(0x6666);

        // contract constructors are inter-dependent so need to precalculate
        // some addresses to correctly initialize immutable storage variables
        DeployAddresses memory addresses;

        // owner creates everything
        vm.startPrank(users.owner);

        // mocks
        mockOracle = new MockOracle();
        stakedBTC = new StakedBTC();
        ++addresses.nonce;

        addresses.core = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.priceFeed = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.feeReceiver = vm.computeCreateAddress(users.owner, ++addresses.nonce);

        // create and configure contracts in the required dependency order
        //
        // Core
        bimaCore = new BimaCore(users.owner, users.guardian, addresses.priceFeed, addresses.feeReceiver);
        assertEq(addresses.core, address(bimaCore));

        // PriceFeed
        priceFeed = new PriceFeed(addresses.core, address(mockOracle));
        assertEq(addresses.priceFeed, address(priceFeed));
        priceFeed.setOracle(
            address(stakedBTC),
            address(mockOracle),
            80000, // heartbeat,
            bytes4(0x00000000), // Read pure data assume stBTC is 1:1 with BTC :)
            18, // sharePriceDecimals
            false //_isEthIndexed
        );
        assertEq(priceFeed.owner(), users.owner);
        assertEq(priceFeed.guardian(), users.guardian);

        // FeeReceiver
        feeReceiver = new FeeReceiver(addresses.core);
        ++addresses.nonce;
        assertEq(addresses.feeReceiver, address(feeReceiver));

        // InterimAdmin
        interimAdmin = new InterimAdmin(addresses.core);
        // not sure why ++addresses.nonce is not required here but it works without it

        // SortedTroves
        sortedTroves = new SortedTroves();
        ++addresses.nonce;

        addresses.tokenWrapperFactory = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.factory = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.liquidationMgr = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.debtToken = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.borrowerOps = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.stabilityPool = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.troveMgr = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.tokenLocker = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.incentiveVoting = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.bimaToken = vm.computeCreateAddress(users.owner, ++addresses.nonce);
        addresses.bimaVault = vm.computeCreateAddress(users.owner, ++addresses.nonce);

        // Token Wrapper Factory
        tokenWrapperFactory = new TokenWrapperFactory(addresses.factory);
        assertEq(addresses.tokenWrapperFactory, address(tokenWrapperFactory));

        // Factory
        factory = new Factory(
            addresses.core,
            IDebtToken(addresses.debtToken),
            IStabilityPool(addresses.stabilityPool),
            IBorrowerOperations(addresses.borrowerOps),
            address(sortedTroves),
            addresses.troveMgr,
            ILiquidationManager(addresses.liquidationMgr),
            TokenWrapperFactory(addresses.tokenWrapperFactory)
        );
        assertEq(addresses.factory, address(factory));

        // LiquidationManager
        liquidationMgr = new LiquidationManager(
            IStabilityPool(addresses.stabilityPool),
            IBorrowerOperations(addresses.borrowerOps),
            addresses.factory,
            INIT_GAS_COMPENSATION
        );
        assertEq(addresses.liquidationMgr, address(liquidationMgr));

        // DebtToken
        debtToken = new DebtToken(
            "BUSD",
            "BUSD",
            addresses.stabilityPool,
            addresses.borrowerOps,
            bimaCore,
            ZERO_ADDRESS, // LayerZero endpoint
            addresses.factory,
            users.gasPool,
            INIT_GAS_COMPENSATION
        );
        assertEq(addresses.debtToken, address(debtToken));

        // BorrowerOperations
        borrowerOps = new BorrowerOperations(
            addresses.core,
            addresses.debtToken,
            addresses.factory,
            INIT_MIN_NET_DEBT,
            INIT_GAS_COMPENSATION,
            TokenWrapperFactory(addresses.tokenWrapperFactory)
        );
        assertEq(addresses.borrowerOps, address(borrowerOps));

        // StabilityPool
        stabilityPool = new StabilityPool(
            addresses.core,
            IDebtToken(addresses.debtToken),
            IBimaVault(addresses.bimaVault),
            addresses.factory,
            addresses.liquidationMgr
        );
        assertEq(addresses.stabilityPool, address(stabilityPool));

        // TroveManager
        troveMgr = new TroveManager(
            addresses.core,
            users.gasPool,
            addresses.debtToken,
            addresses.borrowerOps,
            addresses.bimaVault,
            addresses.liquidationMgr,
            INIT_GAS_COMPENSATION,
            TokenWrapperFactory(addresses.tokenWrapperFactory)
        );
        assertEq(addresses.troveMgr, address(troveMgr));

        // TokenLocker
        tokenLocker = new TokenLocker(
            addresses.core,
            IBimaToken(addresses.bimaToken),
            IIncentiveVoting(addresses.incentiveVoting),
            users.owner,
            INIT_LOCK_TO_TOKEN_RATIO
        );
        assertEq(addresses.tokenLocker, address(tokenLocker));

        // IncentiveVoting
        incentiveVoting = new IncentiveVoting(addresses.core, ITokenLocker(addresses.tokenLocker), addresses.bimaVault);
        assertEq(addresses.incentiveVoting, address(incentiveVoting));

        // BimaToken
        bimaToken = new BimaToken(
            addresses.bimaVault,
            ZERO_ADDRESS, // LayerZero endpoint
            addresses.tokenLocker
        );
        assertEq(addresses.bimaToken, address(bimaToken));

        // BimaVault
        bimaVault = new BimaVault(
            addresses.core,
            IBimaToken(addresses.bimaToken),
            ITokenLocker(addresses.tokenLocker),
            IIncentiveVoting(addresses.incentiveVoting),
            addresses.stabilityPool,
            users.owner
        );
        assertEq(addresses.bimaVault, address(bimaVault));

        // use Factory to deploy new instances of `TroveManager` and `SortedTroves`
        // to add StakedBTC as valid collateral in the protocol
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

        factory.deployNewInstance(
            address(stakedBTC),
            addresses.priceFeed,
            ZERO_ADDRESS, // customTroveManagerImpl
            ZERO_ADDRESS, // customSortedTrovesImpl
            params
        );

        // 1 TroveManager deployed
        assertEq(1, factory.troveManagerCount());

        // create EmissionSchedule
        uint64[2][] memory scheduledWeeklyPct;
        emissionSchedule = new EmissionSchedule(
            address(bimaCore),
            incentiveVoting,
            bimaVault,
            INIT_ES_LOCK_WEEKS,
            INIT_ES_LOCK_DECAY_WEEKS,
            INIT_ES_WEEKLY_PCT,
            scheduledWeeklyPct
        );

        // EmissionSchedule storage correctly set
        assertEq(emissionSchedule.lockWeeks(), INIT_ES_LOCK_WEEKS);
        assertEq(emissionSchedule.lockDecayWeeks(), INIT_ES_LOCK_DECAY_WEEKS);
        assertEq(emissionSchedule.weeklyPct(), INIT_ES_WEEKLY_PCT);

        // create BoostCalculator
        boostCalc = new BoostCalculator(address(bimaCore), tokenLocker, INIT_BS_GRACE_WEEKS);

        // set up mock vault
        mockVault = new MockVault(IERC20(addresses.debtToken));
        lendingVaultAdapter = new LendingVaultAdapter(addresses.core, addresses.debtToken, address(mockVault));

        // note: the hardhat script had some post deloyment actions
        // leaving them commented out for now unless we need them later
        //
        // Register new TroveManager with BimaVault to receive token emissions
        // address newTroveMsg = factory.troveManagers(0);
        // bimaVault.registerReceiver(newTroveMsg, 2);
        //
        // approve BorrowerOperations for 50 StakedBTC tokens
        // stakedBTC.approve(addresses.borrowerOps, 50e18);
        vm.stopPrank();

        // verify we are in the first week
        assertEq(tokenLocker.getWeek(), 0);
    }

    // common helper functions used in tests
    function _sendStakedBtc(address user, uint256 amount) internal {
        if (user != users.owner) {
            vm.prank(users.owner);
            stakedBTC.transfer(user, amount);
        }
    }

    function _getScaledOraclePrice() internal view returns (uint256 scaledPrice) {
        scaledPrice = uint256(mockOracle.answer()) * 10 ** 10;
    }

    function _vaultSetDefaultInitialParameters() internal {
        uint128[] memory _fixedInitialAmounts;
        IBimaVault.InitialAllowance[] memory initialAllowances;

        vm.prank(users.owner);
        bimaVault.setInitialParameters(
            emissionSchedule,
            boostCalc,
            INIT_BAB_TKN_TOTAL_SUPPLY,
            INIT_VLT_LOCK_WEEKS,
            _fixedInitialAmounts,
            initialAllowances
        );

        // addresses correctly set
        assertEq(address(bimaVault.emissionSchedule()), address(emissionSchedule));
        assertEq(address(bimaVault.boostCalculator()), address(boostCalc));

        // BimaToken supply correct
        assertEq(bimaToken.totalSupply(), INIT_BAB_TKN_TOTAL_SUPPLY);
        assertEq(bimaToken.maxTotalSupply(), INIT_BAB_TKN_TOTAL_SUPPLY);

        // BimaToken supply minted to BimaVault
        assertEq(bimaToken.balanceOf(address(bimaVault)), INIT_BAB_TKN_TOTAL_SUPPLY);

        // BimaVault::unallocatedTotal correct (no initial allowances)
        assertEq(bimaVault.unallocatedTotal(), INIT_BAB_TKN_TOTAL_SUPPLY);

        // BimaVault::totalUpdateWeek correct
        assertEq(bimaVault.totalUpdateWeek(), _fixedInitialAmounts.length + bimaVault.getWeek());

        // BimaVault::lockWeeks correct
        assertEq(bimaVault.lockWeeks(), INIT_VLT_LOCK_WEEKS);
    }

    function _vaultSetupAndLockTokens(
        uint256 user1Allocation,
        bool lock
    ) internal returns (uint256 initialUnallocated) {
        // setup the vault to get BimaTokens which are used for voting
        uint128[] memory _fixedInitialAmounts;
        IBimaVault.InitialAllowance[] memory initialAllowances = new IBimaVault.InitialAllowance[](1);

        // give user1 initial allocation
        initialAllowances[0].receiver = users.user1;
        initialAllowances[0].amount = user1Allocation;

        vm.prank(users.owner);
        bimaVault.setInitialParameters(
            emissionSchedule,
            boostCalc,
            INIT_BAB_TKN_TOTAL_SUPPLY,
            INIT_VLT_LOCK_WEEKS,
            _fixedInitialAmounts,
            initialAllowances
        );

        // addresses correctly set
        assertEq(address(bimaVault.emissionSchedule()), address(emissionSchedule));
        assertEq(address(bimaVault.boostCalculator()), address(boostCalc));

        // BimaToken supply correct
        assertEq(bimaToken.totalSupply(), INIT_BAB_TKN_TOTAL_SUPPLY);
        assertEq(bimaToken.maxTotalSupply(), INIT_BAB_TKN_TOTAL_SUPPLY);

        // BimaToken supply minted to BimaVault
        assertEq(bimaToken.balanceOf(address(bimaVault)), INIT_BAB_TKN_TOTAL_SUPPLY);

        // BimaVault::totalUpdateWeek correct
        assertEq(bimaVault.totalUpdateWeek(), _fixedInitialAmounts.length + bimaVault.getWeek());

        // BimaVault::lockWeeks correct
        assertEq(bimaVault.lockWeeks(), INIT_VLT_LOCK_WEEKS);

        // transfer voting tokens to recipients
        vm.prank(users.user1);
        bimaToken.transferFrom(address(bimaVault), users.user1, user1Allocation);

        // verify recipients have received voting tokens
        assertEq(bimaToken.balanceOf(users.user1), user1Allocation);

        // verify remaining supply is unallocated
        initialUnallocated = bimaVault.unallocatedTotal();
        assertEq(initialUnallocated, INIT_BAB_TKN_TOTAL_SUPPLY - user1Allocation);

        if (lock) {
            // receiver locks up their tokens to get voting weight
            vm.prank(users.user1);
            tokenLocker.lock(users.user1, user1Allocation / INIT_LOCK_TO_TOKEN_RATIO, 52);

            // verify receiver balance after lock; calculated this way because of how
            // lock amount gets scaled down by INIT_LOCK_TO_TOKEN_RATIO then for token
            // transfer scales it up by INIT_LOCK_TO_TOKEN_RATIO
            uint256 users1TokensAfterLock = user1Allocation -
                (user1Allocation / INIT_LOCK_TO_TOKEN_RATIO) *
                INIT_LOCK_TO_TOKEN_RATIO;
            assertEq(bimaToken.balanceOf(users.user1), users1TokensAfterLock);
        }
    }

    function _vaultRegisterReceiver(address receiverAddr, uint256 count) internal returns (uint256 firstReceiverId) {
        // cache next id and system week
        firstReceiverId = incentiveVoting.receiverCount();
        uint16 currentWeek = SafeCast.toUint16(bimaVault.getWeek());

        // owner registers receiver
        vm.prank(users.owner);
        assertTrue(bimaVault.registerReceiver(receiverAddr, count));

        // verify all receivers registered
        for (uint256 i = firstReceiverId; i <= count; i++) {
            (address registeredReceiver, bool isActive, uint16 updatedWeek) = bimaVault.idToReceiver(i);
            assertEq(registeredReceiver, receiverAddr);
            assertTrue(isActive);
            assertEq(updatedWeek, currentWeek);

            assertEq(incentiveVoting.receiverUpdatedWeek(i), currentWeek);
        }

        // Verify IncentiveVoting state
        assertEq(incentiveVoting.receiverCount(), firstReceiverId + count);

        // Verify MockEmissionReceiver state
        MockEmissionReceiver(receiverAddr).assertNotifyRegisteredIdCalled(count);
    }

    function _wrapperTokenBalance(address _collateral, address _account) internal returns (uint256 _balance) {
        TokenWrapper tokenWrapper = tokenWrapperFactory.getWrapper(IERC20(_collateral));
        _balance = tokenWrapper.balanceOf(_account);
    }
}

contract MockEmissionReceiver is IEmissionReceiver, IRewards {
    bool public notifyRegisteredIdCalled;
    uint256[] public lastAssignedIds;
    uint256 public reward;

    function notifyRegisteredId(uint256[] calldata assignedIds) external returns (bool success) {
        notifyRegisteredIdCalled = true;
        lastAssignedIds = assignedIds;
        success = true;
    }

    /**
     * @notice Asserts that notifyRegisteredId was called with the expected number of assigned IDs
     * @dev Added this for testing purposes
     * @param expectedCount The expected number of assigned IDs
     */
    function assertNotifyRegisteredIdCalled(uint256 expectedCount) external view {
        require(notifyRegisteredIdCalled, "notifyRegisteredId was not called");
        require(lastAssignedIds.length == expectedCount, "Unexpected number of assigned IDs");
    }

    function setReward(uint256 newReward) external {
        reward = newReward;
    }

    function vaultClaimReward(address, address) external view returns (uint256 amount) {
        amount = reward;
    }

    function claimableReward(address) external view returns (uint256 amount) {
        amount = reward;
    }
}

contract MockBoostDelegate is IBoostDelegate {
    uint256 feePct;

    function setFeePct(uint256 newFeePct) external {
        feePct = newFeePct;
    }

    function getFeePct(address, address, uint256, uint256, uint256) external view returns (uint256 val) {
        val = feePct;
    }

    function delegatedBoostCallback(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external pure returns (bool success) {
        success = true;
    }
}
