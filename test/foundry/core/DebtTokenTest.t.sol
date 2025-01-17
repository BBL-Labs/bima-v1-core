// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// test setup
import {TestSetup, DebtToken} from "../TestSetup.sol";
import {BIMA_100_PCT} from "../../../contracts/dependencies/Constants.sol";

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract DebtTokenTest is IERC3156FlashBorrower, TestSetup {
    uint256 internal constant MIN_AMOUNT = 1e18;
    uint256 internal constant MAX_AMOUNT = 1_000_000_000_000e18;

    function test_flashLoanFee_invalid_token(address _token, uint256 _borrowAmount) external view {
        vm.assume(_token != address(debtToken));

        assertEq(debtToken.maxFlashLoan(_token), 0);
        assertEq(debtToken.flashFee(_token, _borrowAmount), 0);
    }

    function test_flashLoanFee() external {
        // entire supply initially available to borrow
        assertEq(debtToken.maxFlashLoan(address(debtToken)), type(uint256).max);

        // expected fee for borrowing 1e18
        uint256 borrowAmount = MIN_AMOUNT;
        uint256 expectedFee = (borrowAmount * debtToken.FLASH_LOAN_FEE()) / BIMA_100_PCT;

        // fee should be > 0
        assertTrue(expectedFee > 0);

        // fee should be exactly equal
        assertEq(debtToken.flashFee(address(debtToken), borrowAmount), expectedFee);

        // attempt to exploit rounding down to zero precision loss
        // to get free flash loans by borrowing in small amounts - since
        // DebtToken::flashLoan allows re-entrancy, the function could be re-entered
        // multiple times to borrow larger amounts at zero fee
        borrowAmount = 1111;
        vm.expectRevert("ERC20FlashMint: amount too small");
        debtToken.flashFee(address(debtToken), borrowAmount);
    }

    function test_flashLoan(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        debtToken.flashLoan(this, amount, bytes(""));
    }

    function test_transfer_failToZeroAddress(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the Debt token contract or the zero address");
        debtToken.transfer(address(0), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the Debt token contract or the zero address");
        debtToken.transferFrom(address(this), address(0), amount);
    }

    function test_transfer_failToDebtTokenContractAddress(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the Debt token contract or the zero address");
        debtToken.transfer(address(debtToken), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the Debt token contract or the zero address");
        debtToken.transferFrom(address(this), address(debtToken), amount);
    }

    function test_transfer_failToProtocolContractAddresses(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transfer(address(stabilityPool), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transferFrom(address(this), address(stabilityPool), amount);

        address stakedBTCTroveMgrAddr = factory.troveManagers(0);
        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transfer(stakedBTCTroveMgrAddr, amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transferFrom(address(this), stakedBTCTroveMgrAddr, amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transfer(address(borrowerOps), amount);

        vm.expectRevert("Debt: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
        debtToken.transferFrom(address(this), address(borrowerOps), amount);
    }

    function test_transfer(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), amount);

        assertTrue(debtToken.transfer(users.user2, amount));

        assertEq(debtToken.balanceOf(address(this)), 0);
        assertEq(debtToken.balanceOf(users.user2), amount);
    }

    function test_transferFrom(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), amount);

        debtToken.approve(address(this), amount);
        assertTrue(debtToken.transferFrom(address(this), users.user2, amount));

        assertEq(debtToken.balanceOf(address(this)), 0);
        assertEq(debtToken.balanceOf(users.user2), amount);
    }

    function test_transfer_failLackOfFunds(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        debtToken.transfer(users.user2, amount);
    }

    function test_set_lending_vault_adapter_address() external {
        assertEq(debtToken.lendingVaultAdapterAddress(), address(0));

        vm.startPrank(users.owner);

        debtToken.setLendingVaultAdapterAddress(address(lendingVaultAdapter));

        assertEq(debtToken.lendingVaultAdapterAddress(), address(lendingVaultAdapter));
    }

    function test_set_lending_vault_adapter_address_unauthorized(address _user) external {
        vm.assume(_user != bimaCore.owner());

        vm.startPrank(_user);

        vm.expectRevert();
        debtToken.setLendingVaultAdapterAddress(address(lendingVaultAdapter));
    }

    function test_mint_from_lending_vault_adapter(uint256 amount) external {
        vm.assume(amount <= MAX_AMOUNT);

        vm.prank(users.owner);
        debtToken.setLendingVaultAdapterAddress(address(lendingVaultAdapter));

        uint256 totalSupply = debtToken.totalSupply();

        assertEq(debtToken.balanceOf(address(lendingVaultAdapter)), 0);

        vm.startPrank(address(lendingVaultAdapter));

        debtToken.mint(address(lendingVaultAdapter), amount);

        assertEq(debtToken.balanceOf(address(lendingVaultAdapter)), amount);
        assertEq(debtToken.totalSupply(), totalSupply + amount);
    }

    function test_burn_from_lending_vault_adapter(uint256 mintAmount, uint256 burnAmount) external {
        vm.assume(mintAmount <= MAX_AMOUNT);
        vm.assume(burnAmount <= mintAmount);

        vm.prank(users.owner);
        debtToken.setLendingVaultAdapterAddress(address(lendingVaultAdapter));

        uint256 totalSupply = debtToken.totalSupply();

        assertEq(debtToken.balanceOf(address(lendingVaultAdapter)), 0);

        vm.startPrank(address(lendingVaultAdapter));

        debtToken.mint(address(lendingVaultAdapter), mintAmount);
        debtToken.burn(address(lendingVaultAdapter), burnAmount);

        assertEq(debtToken.balanceOf(address(lendingVaultAdapter)), mintAmount - burnAmount);
        assertEq(debtToken.totalSupply(), totalSupply + mintAmount - burnAmount);
    }

    function onFlashLoan(
        address /*initiator*/,
        address /*token*/,
        uint256 amount,
        uint256 fee,
        bytes calldata /*data*/
    ) external returns (bytes32 returnVal) {
        returnVal = keccak256("ERC3156FlashBorrower.onFlashLoan");

        // mint ourselves the fee
        vm.prank(address(borrowerOps));
        debtToken.mint(address(this), fee);

        // approve debt token contract to take amount + fee
        debtToken.approve(address(debtToken), amount + fee);
    }
}
