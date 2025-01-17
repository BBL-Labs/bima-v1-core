// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BimaOwnable} from "../dependencies/BimaOwnable.sol";
import {BIMA_COLLATERAL_DECIMALS} from "../dependencies/Constants.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {ISortedTroves} from "../interfaces/ISortedTroves.sol";
import {IFactory, IDebtToken, ILiquidationManager, IBorrowerOperations, IStabilityPool} from "../interfaces/IFactory.sol";
import {TokenWrapperFactory} from "../wrappers/TokenWrapper.sol";

/**
    @title Bima Trove Factory
    @notice Deploys cloned pairs of `TroveManager` and `SortedTroves` in order to
            add new collateral types within the system.
 */
contract Factory is IFactory, BimaOwnable {
    using Clones for address;

    // fixed single-deployment contracts
    IDebtToken public immutable debtToken;
    IStabilityPool public immutable stabilityPool;
    ILiquidationManager public immutable liquidationManager;
    IBorrowerOperations public immutable borrowerOperations;

    TokenWrapperFactory public immutable tokenWrapperFactory;

    // implementation contracts, redeployed each time via clone proxy
    address public sortedTrovesImpl;
    address public troveManagerImpl;

    address[] public troveManagers;

    constructor(
        address _bimaCore,
        IDebtToken _debtToken,
        IStabilityPool _stabilityPool,
        IBorrowerOperations _borrowerOperations,
        address _sortedTroves,
        address _troveManager,
        ILiquidationManager _liquidationManager,
        TokenWrapperFactory _tokenWrapperFactory
    ) BimaOwnable(_bimaCore) {
        debtToken = _debtToken;
        stabilityPool = _stabilityPool;
        borrowerOperations = _borrowerOperations;

        sortedTrovesImpl = _sortedTroves;
        troveManagerImpl = _troveManager;
        liquidationManager = _liquidationManager;

        tokenWrapperFactory = _tokenWrapperFactory;
    }

    function troveManagerCount() external view returns (uint256 count) {
        count = troveManagers.length;
    }

    /**
        @notice Deploy new instances of `TroveManager` and `SortedTroves`, adding
                a new collateral type to the system.
        @dev * When using the default `PriceFeed`, ensure it is configured correctly
               prior to calling this function.
             * After calling this function, the owner should also call `Vault.registerReceiver`
               to enable BIMA emissions on the newly deployed `TroveManager`
        @param collateral Collateral token to use in new deployment
        @param priceFeed Custom `PriceFeed` deployment. Leave as `address(0)` to use the default.
        @param customTroveManagerImpl Custom `TroveManager` implementation to clone from.
                                      Leave as `address(0)` to use the default.
        @param customSortedTrovesImpl Custom `SortedTroves` implementation to clone from.
                                      Leave as `address(0)` to use the default.
        @param params Struct of initial parameters to be set on the new trove manager
     */
    function deployNewInstance(
        address collateral,
        address priceFeed,
        address customTroveManagerImpl,
        address customSortedTrovesImpl,
        DeploymentParams memory params
    ) external onlyOwner {
        IERC20Metadata collateralToken = IERC20Metadata(collateral);

        tokenWrapperFactory.createWrapper(collateral);

        address implementation = customTroveManagerImpl == address(0) ? troveManagerImpl : customTroveManagerImpl;
        address troveManager = implementation.cloneDeterministic(bytes32(bytes20(collateral)));
        troveManagers.push(troveManager);

        implementation = customSortedTrovesImpl == address(0) ? sortedTrovesImpl : customSortedTrovesImpl;
        address sortedTroves = implementation.cloneDeterministic(bytes32(bytes20(troveManager)));

        ITroveManager(troveManager).setAddresses(priceFeed, sortedTroves, collateral);
        ISortedTroves(sortedTroves).setAddresses(troveManager);

        // verify that the oracle is correctly working
        ITroveManager(troveManager).fetchPrice();

        stabilityPool.enableCollateral(collateralToken);
        liquidationManager.enableTroveManager(ITroveManager(troveManager));
        debtToken.enableTroveManager(troveManager);
        borrowerOperations.configureCollateral(ITroveManager(troveManager), collateralToken);

        ITroveManager(troveManager).setParameters(
            params.minuteDecayFactor,
            params.redemptionFeeFloor,
            params.maxRedemptionFee,
            params.borrowingFeeFloor,
            params.maxBorrowingFee,
            params.interestRateInBps,
            params.maxDebt,
            params.MCR
        );

        emit NewDeployment(collateral, priceFeed, troveManager, sortedTroves);
    }

    function setImplementations(address _troveManagerImpl, address _sortedTrovesImpl) external onlyOwner {
        troveManagerImpl = _troveManagerImpl;
        sortedTrovesImpl = _sortedTrovesImpl;

        emit ImplementationContractsChanged(_troveManagerImpl, _sortedTrovesImpl);
    }
}
