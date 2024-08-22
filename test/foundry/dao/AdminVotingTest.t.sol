// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {AdminVoting} from "../../../contracts/dao/AdminVoting.sol";
import {IBabelCore} from "../../../contracts/interfaces/IBabelCore.sol";

// test setup
import {TestSetup, IBabelVault} from "../TestSetup.sol";

contract AdminVotingTest is TestSetup {
    AdminVoting adminVoting;


    uint256 constant internal INIT_MIN_CREATE_PROP_PCT = 10;   // 0.01%
    uint256 constant internal UPDT_MIN_CREATE_PROP_PCT = 50;   // 0.05%
    uint256 constant internal INIT_PROP_PASSING_PCT    = 2000; // 20%
    uint256 constant internal UPDT_PROP_PASSING_PCT    = 3000; // 30%

    uint256 constant internal USER1_TOKEN_ALLOCATION = INIT_BAB_TKN_TOTAL_SUPPLY * 8000/10000;
    uint256 constant internal USER2_TOKEN_ALLOCATION = INIT_BAB_TKN_TOTAL_SUPPLY * 2000/10000;

    function setUp() public virtual override {
        super.setUp();

        adminVoting = new AdminVoting(address(babelCore),
                                      tokenLocker,
                                      INIT_MIN_CREATE_PROP_PCT,
                                      INIT_PROP_PASSING_PCT);

        // setup the vault to get BabelTokens which are used for voting
        uint128[] memory _fixedInitialAmounts;
        IBabelVault.InitialAllowance[] memory initialAllowances 
            = new IBabelVault.InitialAllowance[](2);
        
        // give user1 80% and user2 20% of token allocation
        initialAllowances[0].receiver = users.user1;
        initialAllowances[0].amount = USER1_TOKEN_ALLOCATION;
        initialAllowances[1].receiver = users.user2;
        initialAllowances[1].amount = USER2_TOKEN_ALLOCATION;

        vm.prank(users.owner);
        babelVault.setInitialParameters(emissionSchedule,
                                        boostCalc,
                                        INIT_BAB_TKN_TOTAL_SUPPLY,
                                        INIT_VLT_LOCK_WEEKS,
                                        _fixedInitialAmounts,
                                        initialAllowances);

        // transfer voting tokens to recipients
        vm.prank(users.user1);
        babelToken.transferFrom(address(babelVault), users.user1, USER1_TOKEN_ALLOCATION);
        vm.prank(users.user2);
        babelToken.transferFrom(address(babelVault), users.user2, USER2_TOKEN_ALLOCATION);

        // verify recipients have received voting tokens
        assertEq(babelToken.balanceOf(users.user1), USER1_TOKEN_ALLOCATION);
        assertEq(babelToken.balanceOf(users.user2), USER2_TOKEN_ALLOCATION);
    }

    function test_constructor() external view {
        // parameters correctly set
        assertEq(adminVoting.minCreateProposalPct(), INIT_MIN_CREATE_PROP_PCT);
        assertEq(adminVoting.passingPct(), INIT_PROP_PASSING_PCT);
        assertEq(address(adminVoting.tokenLocker()), address(tokenLocker));

        // week initialized to zero
        assertEq(adminVoting.getWeek(), 0);
        assertEq(adminVoting.minCreateProposalWeight(), 0);

        // no proposals
        assertEq(adminVoting.getProposalCount(), 0);
    }

    function test_createNewProposal_noVotingWeight() external {
        // create dummy proposal
        AdminVoting.Action[] memory payload = new AdminVoting.Action[](1);
        payload[0].target = address(0x0);
        payload[0].data   = abi.encode("");

        uint256 lastProposalTimestamp = adminVoting.latestProposalTimestamp(users.user1);
        assertEq(lastProposalTimestamp, 0);

        // verify no proposals can be created in first week
        vm.startPrank(users.user1);
        vm.expectRevert("No proposals in first week");
        adminVoting.createNewProposal(users.user1, payload);

        // advance time by 1 week
        vm.warp(block.timestamp + 1 weeks);
        uint256 weekNum = 1;
        assertEq(adminVoting.getWeek(), weekNum);

        // verify there are no tokens locked
        assertEq(tokenLocker.getTotalWeightAt(weekNum), 0);

        // verify no proposals can be created if there is no
        // total voting weight in that week
        vm.expectRevert("Zero total voting weight for given week");
        adminVoting.createNewProposal(users.user1, payload);
        vm.stopPrank();
    }

    // helper function to verify proposal data after creation
    function _verifyCreatedProposal(uint256 proposalId, 
                                    uint256 proposalWeek,
                                    uint256 proposalPassingPct,
                                    AdminVoting.Action[] memory payload) internal view {
        // verify requiredWeight calculated using correct passing percent
        assertEq(adminVoting.getProposalRequiredWeight(proposalId), 
                 (tokenLocker.getTotalWeightAt(proposalWeek) * proposalPassingPct) /
                 adminVoting.MAX_PCT());
        // verify proposal details stored correctly
        assertEq(adminVoting.getProposalWeek(proposalId), proposalWeek);
        assertEq(adminVoting.getProposalCreatedAt(proposalId), block.timestamp);
        assertEq(adminVoting.getProposalCurrentWeight(proposalId), 0);
        assertEq(adminVoting.getProposalCanExecuteAfter(proposalId), 0);
        assertEq(adminVoting.getProposalProcessed(proposalId), false);
        assertEq(adminVoting.getProposalCanExecute(proposalId), false);

        // verify payload correctly saved
        AdminVoting.Action[] memory savedPayload = adminVoting.getProposalPayload(proposalId);
        assertEq(payload.length, savedPayload.length);

        for(uint256 i; i<payload.length; i++) {
            assertEq(payload[i].target, savedPayload[i].target);
            assertEq(payload[i].data, savedPayload[i].data);
        }
    }

    function test_createNewProposal_setGuardian() public returns(uint256 proposalId) {
        // create a setGuardian proposal that also contains other payloads
        AdminVoting.Action[] memory payload = new AdminVoting.Action[](3);
        payload[0].target = address(adminVoting);
        payload[0].data   = abi.encodeWithSelector(AdminVoting.setMinCreateProposalPct.selector, UPDT_MIN_CREATE_PROP_PCT);
        payload[1].target = address(adminVoting);
        payload[1].data   = abi.encodeWithSelector(AdminVoting.setPassingPct.selector, UPDT_PROP_PASSING_PCT);
        payload[2].target = address(babelCore);
        payload[2].data   = abi.encodeWithSelector(IBabelCore.setGuardian.selector, users.user1);

        // lock up user tokens to receive voting power
        vm.prank(users.user1);
        tokenLocker.lock(users.user1, USER1_TOKEN_ALLOCATION, 52);

        // warp forward BOOTSTRAP_PERIOD so voting power becomes active
        // and setGuardian proposals are allowed
        vm.warp(block.timestamp + adminVoting.BOOTSTRAP_PERIOD());

        // create the proposal
        vm.prank(users.user1);
        proposalId = adminVoting.createNewProposal(users.user1, payload);

        _verifyCreatedProposal(proposalId,
                               adminVoting.getWeek()-1,
                               adminVoting.SET_GUARDIAN_PASSING_PCT(),
                               payload);
    }

    function test_createNewProposal_withVotingWeight() public returns(uint256 proposalId) {
        // create proposal that updates 2 internal AdminVoting parameters
        AdminVoting.Action[] memory payload = new AdminVoting.Action[](2);
        payload[0].target = address(adminVoting);
        payload[0].data   = abi.encodeWithSelector(AdminVoting.setMinCreateProposalPct.selector, UPDT_MIN_CREATE_PROP_PCT);
        payload[1].target = address(adminVoting);
        payload[1].data   = abi.encodeWithSelector(AdminVoting.setPassingPct.selector, UPDT_PROP_PASSING_PCT);

        // lock up user tokens to receive voting power
        vm.prank(users.user1);
        tokenLocker.lock(users.user1, USER1_TOKEN_ALLOCATION, 52);

        // advance time by 1 week
        vm.warp(block.timestamp + 1 weeks);
        uint256 weekNum = 1;
        assertEq(adminVoting.getWeek(), weekNum);

        // create the proposal
        vm.prank(users.user1);
        proposalId = adminVoting.createNewProposal(users.user1, payload);

        _verifyCreatedProposal(proposalId,
                               weekNum-1,
                               adminVoting.passingPct(),
                               payload);
    }

    function test_createNewProposal_minTimeBetweenProposals() external {
        // create first proposal
        test_createNewProposal_withVotingWeight();

        // verify attempting to quickly create another fails
        AdminVoting.Action[] memory payload = new AdminVoting.Action[](1);
        payload[0].target = address(0x0);
        payload[0].data   = abi.encode("");

        vm.expectRevert("MIN_TIME_BETWEEN_PROPOSALS");
        vm.prank(users.user1);
        adminVoting.createNewProposal(users.user1, payload);

        // advance time by the minimum time between proposals
        vm.warp(block.timestamp + adminVoting.MIN_TIME_BETWEEN_PROPOSALS() + 1);

        // now user can create another proposal
        vm.prank(users.user1);
        adminVoting.createNewProposal(users.user1, payload);

        // verify requiredWeight calculated using standard passing percent
        assertEq(adminVoting.getProposalRequiredWeight(1), 
                 (tokenLocker.getTotalWeightAt(adminVoting.getWeek()-1) * adminVoting.passingPct()) /
                 adminVoting.MAX_PCT());
    }

    // helper function to successfully cancel a proposal
    function _cancelProposal(uint256 proposalId) internal {
        // verify cancel works for guardian
        vm.prank(users.guardian);
        adminVoting.cancelProposal(proposalId);

        // verify storage correctly updated
        assertEq(adminVoting.getProposalProcessed(proposalId), true);

        // verify proposal can't be executed
        assertEq(adminVoting.getProposalCanExecute(proposalId), false);
    }

    function test_cancelProposal_onlyGuardianCanCancel() external {
        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // verify fails if non-guardian tries to cancel
        vm.expectRevert("Only guardian can cancel proposals");
        vm.prank(users.user1);
        adminVoting.cancelProposal(proposalId);

        _cancelProposal(proposalId);
    }

    function test_cancelProposal_cantCancelSetGuardian() external {
        // create the setGuardian proposal
        uint256 proposalId = test_createNewProposal_setGuardian();

        // verify it is impossible to cancel
        vm.expectRevert("Guardian replacement not cancellable");
        vm.prank(users.guardian);
        adminVoting.cancelProposal(proposalId);
    }

    function test_cancelProposal_cantCancelCancelledProposal() external {
        // create the proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // cancel it
        _cancelProposal(proposalId);

        // verify cancelling already cancelled proposal fails
        vm.expectRevert("Already processed");
        vm.prank(users.guardian);
        adminVoting.cancelProposal(proposalId);
    }

    // helper function used to make a successful vote
    function _voteForProposal(address voter, uint256 proposalId, uint256 votingWeight) internal {
        uint256 previousWeight = adminVoting.getProposalCurrentWeight(proposalId);

        // vote on it
        vm.prank(voter);
        adminVoting.voteForProposal(voter, proposalId, votingWeight);

        // verify current voting weight correctly updated
        assertEq(adminVoting.getProposalCurrentWeight(proposalId)-previousWeight, votingWeight);
        // verify proposal still not processed
        assertEq(adminVoting.getProposalProcessed(proposalId), false);
        // verify proposal can't be executed
        assertEq(adminVoting.getProposalCanExecute(proposalId), false);

        // if proposal has passed, verify executeAfter correctly set
        if(adminVoting.getProposalPassed(proposalId)) {
            assertEq(adminVoting.getProposalCanExecuteAfter(proposalId),
                     block.timestamp + adminVoting.MIN_TIME_TO_EXECUTION());
        }
        // otherwise verify proposal has not passed
        else {
            assertEq(adminVoting.getProposalCanExecuteAfter(proposalId), 0);
        }
    }

    function test_voteForProposal(uint256 votingWeight) external {
        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // bind fuzz inputs
        votingWeight = bound(votingWeight,
                              1,
                              tokenLocker.getAccountWeightAt(users.user1,
                                                             adminVoting.getProposalWeek(proposalId)));

        _voteForProposal(users.user1, proposalId, votingWeight);
    }

    function test_voteForProposal_differentVotersAccumulate() external {
        // lock up user2 tokens to receive voting power
        vm.prank(users.user2);
        tokenLocker.lock(users.user2, USER2_TOKEN_ALLOCATION, 52);

        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // each user votes with 50 weight
        uint256 votingWeight = 50;

        _voteForProposal(users.user1, proposalId, votingWeight);
        _voteForProposal(users.user2, proposalId, votingWeight);

        // verify proposal's voting weight has accumulated from both votes
        assertEq(adminVoting.getProposalCurrentWeight(proposalId), votingWeight*2);
    }

    function test_voteForProposal_canVoteOnPassedProposal() external {
        // lock up user2 tokens to receive voting power
        vm.prank(users.user2);
        tokenLocker.lock(users.user2, USER2_TOKEN_ALLOCATION, 52);

        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // first user votes with enough weight to pass proposal
        _voteForProposal(users.user1,
                         proposalId,
                         tokenLocker.getAccountWeightAt(users.user1,
                                                        adminVoting.getProposalWeek(proposalId)));
                                                    
        // verify proposal has passed
        assertEq(adminVoting.getProposalPassed(proposalId), true);

        // verify it hasn't been cancelled or executed
        assertEq(adminVoting.getProposalProcessed(proposalId), false);

        // user2 can still vote on the proposal, even though it has passed
        _voteForProposal(users.user2,
                         proposalId,
                         tokenLocker.getAccountWeightAt(users.user2,
                                                        adminVoting.getProposalWeek(proposalId)));
    }

    function test_voteForProposal_cantVoteWithMoreWeight(uint256 votingWeight) external {
        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        // bind fuzz inputs
        votingWeight = bound(votingWeight,
                              tokenLocker.getAccountWeightAt(users.user1,
                                                             adminVoting.getProposalWeek(proposalId)) + 1,
                              type(uint256).max);

        // verify voting with more weight than an account has fails
        vm.expectRevert("Weight exceeds account weight");
        vm.prank(users.user1);
        adminVoting.voteForProposal(users.user1, proposalId, votingWeight);
    }

    function test_voteForProposal_sameUserCantVoteTwice() external {
        // create first proposal
        uint256 proposalId = test_createNewProposal_withVotingWeight();

        uint256 halfVotingWeight
            = tokenLocker.getAccountWeightAt(users.user1,
                                             adminVoting.getProposalWeek(proposalId)) / 2;

        // vote once works
        _voteForProposal(users.user1, proposalId, halfVotingWeight);

        // voting twice fails
        vm.expectRevert("Already voted");
        vm.prank(users.user1);
        adminVoting.voteForProposal(users.user1, proposalId, halfVotingWeight);
    }

    // helper function to successfully execute a proposal
    function _executeProposal(address voter, uint256 proposalId) internal {
        // vote with full weight so proposal passes
        _voteForProposal(voter,
                         proposalId,
                         tokenLocker.getAccountWeightAt(voter,
                                                        adminVoting.getProposalWeek(proposalId)));

        // warp to after proposal execution time
        vm.warp(adminVoting.getProposalCanExecuteAfter(proposalId) + 1);

        // verify proposal can be executed
        assertEq(adminVoting.getProposalCanExecute(proposalId), true);

        // execute the proposal
        adminVoting.executeProposal(proposalId);

        // verify the min create proposal percentage was updated
        assertEq(adminVoting.minCreateProposalPct(), UPDT_MIN_CREATE_PROP_PCT);

        // verify the pass percentage was updated
        assertEq(adminVoting.passingPct(), UPDT_PROP_PASSING_PCT);
    }

    function test_executeProposal_setGuardian() public returns(uint256 proposalId) {
        // transfer ownership of BabelCore to the DAO
        vm.prank(users.owner);
        babelCore.commitTransferOwnership(address(adminVoting));
        vm.warp(block.timestamp + babelCore.OWNERSHIP_TRANSFER_DELAY() + 1);
        adminVoting.acceptTransferOwnership();
        assertEq(babelCore.owner(), address(adminVoting));

        // create the `setGuardian` proposal which also calls
        // `setPassingPct` and `setMinCreateProposalPct`
        proposalId = test_createNewProposal_setGuardian();

        _executeProposal(users.user1, proposalId);

        // verify the guardian was updated
        assertEq(babelCore.guardian(), address(users.user1));
    }

    function test_executeProposal_cantExecuteTwice() external {
        // execute once
        uint256 executedProposalId = test_executeProposal_setGuardian();

        // verify second execution of same proposal fails
        vm.expectRevert("Already processed");
        adminVoting.executeProposal(executedProposalId);
    }

    function test_executeProposal_withoutSetGuardian() public returns(uint256 proposalId) {
        // create the proposal
        proposalId = test_createNewProposal_withVotingWeight();

        _executeProposal(users.user1, proposalId);
    }

    function test_executeProposal_cantCancelExecutedProposal() external {
        // execute once
        uint256 executedProposalId = test_executeProposal_withoutSetGuardian();

        // verify cancelling already executed proposal fails
        vm.expectRevert("Already processed");
        vm.prank(users.guardian);
        adminVoting.cancelProposal(executedProposalId);
    }
}