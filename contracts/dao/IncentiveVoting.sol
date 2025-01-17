// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {DelegatedOps} from "../dependencies/DelegatedOps.sol";
import {SystemStart} from "../dependencies/SystemStart.sol";
import {IIncentiveVoting, ITokenLocker} from "../interfaces/IIncentiveVoting.sol";
import {IBimaVault} from "../interfaces/IVault.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
    @title Bima Incentive Voting
    @notice Users with BIMA balances locked in `TokenLocker` may register their
            lock weights in this contract, and use this weight to vote on where
            new BIMA emissions will be released in the following week.

            Conceptually, incentive voting functions similarly to Curve's gauge weight voting.
 */
contract IncentiveVoting is IIncentiveVoting, DelegatedOps, SystemStart {
    uint256 public constant MAX_POINTS = 10000; // must be less than 2**16 or things will break
    uint256 public constant MAX_LOCK_WEEKS = 52; // must be the same as `MultiLocker`

    ITokenLocker public immutable tokenLocker;
    address public immutable vault;

    struct AccountData {
        // system week when the account's lock weights were registered
        // used to offset `weeksToUnlock` when calculating vote weight
        // as it decays over time
        uint16 week;
        // total registered vote weight, only recorded when frozen.
        // for unfrozen weight, recording the total is unnecessary because the
        // value decays. throughout the code, we check if frozenWeight > 0 as
        // a way to indicate if a lock is frozen.
        uint40 frozenWeight;
        uint16 points;
        uint8 lockLength; // length of weeksToUnlock and lockedAmounts
        uint16 voteLength; // length of activeVotes
        // array of [(receiver id, points), ... ] stored as uint16[2] for optimal packing
        uint16[2][MAX_POINTS] activeVotes;
        // arrays map to one another: lockedAmounts[0] unlocks in weeksToUnlock[0] weeks
        // values are sorted by time-to-unlock descending
        uint32[MAX_LOCK_WEEKS] lockedAmounts;
        uint8[MAX_LOCK_WEEKS] weeksToUnlock;
    }

    mapping(address account => AccountData lockData) accountLockData;

    uint256 public receiverCount;
    // id -> receiver data
    uint32[65535] public receiverDecayRate;
    uint16[65535] public receiverUpdatedWeek;
    // id -> week -> absolute vote weight
    uint40[65535][65535] receiverWeeklyWeights;
    // id -> week -> registered lock weight that is lost
    uint32[65535][65535] public receiverWeeklyUnlocks;

    uint32 public totalDecayRate;
    uint16 public totalUpdatedWeek;
    uint40[65535] totalWeeklyWeights;
    uint32[65535] public totalWeeklyUnlocks;

    constructor(address _bimaCore, ITokenLocker _tokenLocker, address _vault) SystemStart(_bimaCore) {
        tokenLocker = _tokenLocker;
        vault = _vault;
    }

    function getAccountRegisteredLocks(
        address account
    ) external view returns (uint256 frozenWeight, ITokenLocker.LockData[] memory lockData) {
        frozenWeight = accountLockData[account].frozenWeight;
        lockData = _getAccountLocks(account);
    }

    function getAccountCurrentVotes(address account) public view returns (Vote[] memory votes) {
        votes = new Vote[](accountLockData[account].voteLength);
        uint16[2][MAX_POINTS] storage storedVotes = accountLockData[account].activeVotes;
        uint256 length = votes.length;
        for (uint256 i; i < length; i++) {
            votes[i] = Vote({id: storedVotes[i][0], points: storedVotes[i][1]});
        }
    }

    function getReceiverWeight(uint256 idx) external view returns (uint256 weight) {
        weight = getReceiverWeightAt(idx, getWeek());
    }

    function getReceiverWeightAt(uint256 idx, uint256 week) public view returns (uint256 weight) {
        // if idx >= receiver count nothing to do, default 0 will be returned
        if (idx < receiverCount) {
            // get last updated week for input idx
            uint256 updatedWeek = receiverUpdatedWeek[idx];

            // if input week has already been processed, return answer from storage
            if (week <= updatedWeek) return receiverWeeklyWeights[idx][week];

            // otherwise read weight from idx's last updated week
            weight = receiverWeeklyWeights[idx][updatedWeek];

            // if not 0, perform additional processing
            if (weight != 0) {
                // cache decay rate from idx storage
                uint256 rate = receiverDecayRate[idx];

                // iterate over unprocessed weeks until input week,
                // adjusting the weight by decay rate and decay
                // rate by weekly unlocks
                while (updatedWeek < week) {
                    updatedWeek++;
                    weight -= rate;
                    rate -= receiverWeeklyUnlocks[idx][updatedWeek];
                }
            }
        }
    }

    function getTotalWeight() external view returns (uint256 weight) {
        weight = getTotalWeightAt(getWeek());
    }

    function getTotalWeightAt(uint256 week) public view returns (uint256 weight) {
        // get last updated week for total weight
        uint256 updatedWeek = totalUpdatedWeek;

        // if input week has already been processed, return answer from storage
        if (week <= updatedWeek) return totalWeeklyWeights[week];

        // otherwise read weight from total weight's last updated week
        weight = totalWeeklyWeights[updatedWeek];

        // if not 0, perform additional processing
        if (weight != 0) {
            // cache total decay rate from storage; this represents the
            // rate at the last updated week so is the correct rate to
            // start from
            uint256 rate = totalDecayRate;

            // iterate over unprocessed weeks until input week,
            // adjusting the weight by decay rate and decay
            // rate by weekly unlocks
            while (updatedWeek < week) {
                updatedWeek++;
                weight -= rate;
                rate -= totalWeeklyUnlocks[updatedWeek];
            }
        }
    }

    function getReceiverWeightWrite(uint256 idx) public returns (uint256 weight) {
        // revert for invalid idx
        require(idx < receiverCount, "Invalid ID");

        // get current system week
        uint256 week = getWeek();

        // get last updated week for input idx
        uint256 updatedWeek = receiverUpdatedWeek[idx];

        // output weight from idx's last updated week
        weight = receiverWeeklyWeights[idx][updatedWeek];

        // if zero, just update the idx last updated week
        // to the current system week
        if (weight == 0) {
            receiverUpdatedWeek[idx] = SafeCast.toUint16(week);
        }
        // otherwise perform additional processing
        else {
            // cache decay rate from idx storage
            uint256 rate = receiverDecayRate[idx];

            // iterate over unprocessed weeks until current system
            // week, adjusting the weight by decay rate and decay
            // rate by weekly unlocks
            while (updatedWeek < week) {
                updatedWeek++;
                weight -= rate;
                // update storage weekly idx weight
                receiverWeeklyWeights[idx][updatedWeek] = SafeCast.toUint40(weight);

                // adjust rate by weekly unlocks
                rate -= receiverWeeklyUnlocks[idx][updatedWeek];
            }

            // finally update idx decay rate and last processed week
            receiverDecayRate[idx] = SafeCast.toUint32(rate);
            receiverUpdatedWeek[idx] = SafeCast.toUint16(week);
        }
    }

    function getTotalWeightWrite() public returns (uint256 weight) {
        // get current system week
        uint256 week = getWeek();

        // get last updated week for total weight
        uint256 updatedWeek = totalUpdatedWeek;

        // output weight from total weight's last updated week
        weight = totalWeeklyWeights[updatedWeek];

        // if zero, just update the total weight last updated week
        // to the current system week
        if (weight == 0) {
            totalUpdatedWeek = SafeCast.toUint16(week);
        }
        // otherwise perform additional processing
        else {
            // cache total decay rate from storage; this represents the
            // rate at the last updated week so is the correct rate to
            // start from
            uint256 rate = totalDecayRate;

            // iterate over unprocessed weeks until current system week,
            // adjusting the weight by decay rate and decay rate by weekly
            // unlocks
            while (updatedWeek < week) {
                updatedWeek++;
                weight -= rate;

                // update storage weekly total weight
                totalWeeklyWeights[updatedWeek] = SafeCast.toUint40(weight);

                // adjust rate by weekly unlocks
                rate -= totalWeeklyUnlocks[updatedWeek];
            }

            // finally update total decay rate and last processed week
            totalDecayRate = SafeCast.toUint32(rate);
            totalUpdatedWeek = SafeCast.toUint16(week);
        }
    }

    function getReceiverVoteInputs(
        uint256 id,
        uint256 week
    ) external returns (uint256 totalWeeklyWeight, uint256 receiverWeeklyWeight) {
        // lookback one week
        week -= 1;

        // update storage - id & total weights for any
        // missing weeks up to current system week
        getReceiverWeightWrite(id);
        getTotalWeightWrite();

        // output total weight for lookback week
        totalWeeklyWeight = totalWeeklyWeights[week];

        // if not zero, also output receiver weekly weight
        if (totalWeeklyWeight != 0) {
            receiverWeeklyWeight = receiverWeeklyWeights[id][week];
        }
    }

    function getReceiverVotePct(uint256 id, uint256 week) external returns (uint256 votePct) {
        // lookback one week
        week -= 1;

        // update storage - id & total weights for any
        // missing weeks up to current system week
        getReceiverWeightWrite(id);
        getTotalWeightWrite();

        // output total weight for lookback week
        votePct = totalWeeklyWeights[week];

        // if not zero, calculate the actual vote percent
        // for the lookback week; using votePct as denominator
        // since it contains the totalWeight
        if (votePct != 0) {
            votePct = (1e18 * uint256(receiverWeeklyWeights[id][week])) / votePct;
        }
    }

    function registerNewReceiver() external returns (uint256 id) {
        // only vault can register new receivers
        require(msg.sender == vault, "Not Treasury");

        // output current value then increment storage
        id = receiverCount++;

        // set last processed week to current system week
        receiverUpdatedWeek[id] = SafeCast.toUint16(getWeek());
    }

    /**
        @notice Record the current lock weights for `account`, which can then
                be used to vote.
        @param minWeeks The minimum number of weeks-to-unlock to record weights
                        for. The more active lock weeks that are registered, the
                        more expensive it will be to vote. Accounts with many active
                        locks may wish to skip smaller locks to reduce gas costs.
     */
    function registerAccountWeight(address account, uint256 minWeeks) external callerOrDelegated(account) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        Vote[] memory existingVotes;

        // if account has an active vote, clear the recorded vote
        // weights prior to updating the registered account weights
        if (accountData.voteLength > 0) {
            existingVotes = getAccountCurrentVotes(account);
            _removeVoteWeights(account, existingVotes, accountData.frozenWeight);
            emit ClearedVotes(account, getWeek());
        }

        // get updated account lock weights and store locally
        uint256 frozenWeight = _registerAccountWeight(account, minWeeks);

        // resubmit the account's active vote using the newly registered weights
        _addVoteWeights(account, existingVotes, frozenWeight);
        // do not call `_storeAccountVotes` because the vote is unchanged
    }

    /**
        @notice Record the current lock weights for `account` and submit new votes
        @dev New votes replace any prior active votes
        @param minWeeks Minimum number of weeks-to-unlock to record weights for
        @param votes Array of tuples of (recipient id, vote points)
     */
    function registerAccountWeightAndVote(
        address account,
        uint256 minWeeks,
        Vote[] calldata votes
    ) external callerOrDelegated(account) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // if account has an active vote, clear the recorded vote
        // weights prior to updating the registered account weights
        if (accountData.voteLength > 0) {
            _removeVoteWeights(account, getAccountCurrentVotes(account), accountData.frozenWeight);
            emit ClearedVotes(account, getWeek());
        }

        // get updated account lock weights and store locally
        uint256 frozenWeight = _registerAccountWeight(account, minWeeks);

        // adjust vote weights based on the account's new vote
        _addVoteWeights(account, votes, frozenWeight);
        // store the new account votes
        _storeAccountVotes(account, accountData, votes, 0, 0);
    }

    /**
        @notice Vote for one or more recipients
        @dev * Each voter can vote with up to `MAX_POINTS` points
             * It is not required to use every point in a single call
             * Votes carry over week-to-week and decay at the same rate as lock
               weight
             * The total weight is NOT distributed porportionally based on the
               points used, an account must allocate all points in order to use
               it's full vote weight
        @param votes Array of tuples of (recipient id, vote points)
        @param clearPrevious if true, the voter's current votes are cleared
                             prior to recording the new votes. If false, new
                             votes are added in addition to previous votes.
     */
    function vote(address account, Vote[] calldata votes, bool clearPrevious) external callerOrDelegated(account) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // cache account's frozen weight
        uint256 frozenWeight = accountData.frozenWeight;

        // revert if no frozen weight or no locks
        require(frozenWeight > 0 || accountData.lockLength > 0, "No registered weight");

        // working data
        uint256 points;
        uint256 offset;

        // optionally clear previous votes
        if (clearPrevious) {
            _removeVoteWeights(account, getAccountCurrentVotes(account), frozenWeight);
            emit ClearedVotes(account, getWeek());
        } else {
            points = accountData.points;
            offset = accountData.voteLength;
        }

        // adjust vote weights based on the new vote
        _addVoteWeights(account, votes, frozenWeight);
        // store the new account votes
        _storeAccountVotes(account, accountData, votes, points, offset);
    }

    /**
        @notice Remove all active votes for the caller
     */
    function clearVote(address account) external callerOrDelegated(account) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // cache account's frozen weight
        uint256 frozenWeight = accountData.frozenWeight;

        // clear account's current votes
        _removeVoteWeights(account, getAccountCurrentVotes(account), frozenWeight);

        // reset voteLength & points
        accountData.voteLength = 0;
        accountData.points = 0;

        emit ClearedVotes(account, getWeek());
    }

    /**
        @notice Clear registered weight and votes for `account`
        @dev Called by `tokenLocker` when an account performs an early withdrawal
             of locked tokens, to prevent a registered weight > actual lock weight
     */
    function clearRegisteredWeight(address account) external returns (bool success) {
        require(
            msg.sender == account || msg.sender == address(tokenLocker) || isApprovedDelegate[account][msg.sender],
            "Delegate not approved"
        );

        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // get current system week
        uint256 week = getWeek();

        // cache number of account's locks
        uint256 length = accountData.lockLength;

        // cache account's frozen weight
        uint256 frozenWeight = accountData.frozenWeight;

        if (length > 0 || frozenWeight > 0) {
            // clear any current votes
            if (accountData.voteLength > 0) {
                _removeVoteWeights(account, getAccountCurrentVotes(account), frozenWeight);
                accountData.voteLength = 0;
                accountData.points = 0;

                emit ClearedVotes(account, week);
            }

            // lockLength and frozenWeight are never both > 0
            if (length > 0) accountData.lockLength = 0;
            else accountData.frozenWeight = 0;

            emit AccountWeightRegistered(account, week, 0, new ITokenLocker.LockData[](0));
        }

        success = true;
    }

    /**
        @notice Set a frozen account weight as unfrozen
        @dev Callable only by the token locker. This prevents users from
             registering frozen locks, unfreezing, and having a larger registered
             vote weight than their actual lock weight.
     */
    function unfreeze(address account, bool keepVote) external returns (bool success) {
        // only tokenLocker can call this function
        require(msg.sender == address(tokenLocker), "!tokenLocker");

        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // cache account's frozen weight
        uint256 frozenWeight = accountData.frozenWeight;

        // get current system week
        uint256 week = getWeek();

        // if user had frozen weight, reset it and clear optionally
        // clear their votes using frozen weight
        if (frozenWeight > 0) {
            // clear previous votes
            Vote[] memory existingVotes;

            if (accountData.voteLength > 0) {
                existingVotes = getAccountCurrentVotes(account);
                _removeVoteWeightsFrozen(existingVotes, frozenWeight);
            }

            accountData.week = SafeCast.toUint16(week);
            accountData.frozenWeight = 0;

            uint256 amount = frozenWeight / MAX_LOCK_WEEKS;
            accountData.lockedAmounts[0] = SafeCast.toUint32(amount);
            accountData.weeksToUnlock[0] = uint8(MAX_LOCK_WEEKS);
            accountData.lockLength = 1;

            // optionally resubmit previous votes
            if (existingVotes.length > 0) {
                if (keepVote) {
                    _addVoteWeightsUnfrozen(account, existingVotes);
                } else {
                    accountData.voteLength = 0;
                    accountData.points = 0;
                    emit ClearedVotes(account, week);
                }
            }

            ITokenLocker.LockData[] memory lockData = new ITokenLocker.LockData[](1);
            lockData[0] = ITokenLocker.LockData({amount: amount, weeksToUnlock: MAX_LOCK_WEEKS});
            emit AccountWeightRegistered(account, week, 0, lockData);
        }
        // user may have had votes registered prior to freezing their weight so
        // remove these if the user doesn't want to keep their votes
        else if (!keepVote) {
            // clear previous votes
            if (accountData.voteLength > 0) {
                _removeVoteWeights(account, getAccountCurrentVotes(account), 0);

                accountData.voteLength = 0;
                accountData.points = 0;

                emit ClearedVotes(account, week);
            }
        }

        success = true;
    }

    /**
        @dev Get the current registered lock weights for `account`, as an array
             of [(amount, weeks to unlock)] sorted by weeks-to-unlock descending.
     */
    function _getAccountLocks(address account) internal view returns (ITokenLocker.LockData[] memory lockData) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        // cache number of account's locks
        uint256 length = accountData.lockLength;

        // get current system week
        uint256 systemWeek = getWeek();

        // if account has frozen weight use system week
        // else use account's last processed week
        uint256 accountWeek = accountData.frozenWeight > 0 ? systemWeek : accountData.week;

        // get storage references to account's unlock weeks & locked amounts
        uint8[MAX_LOCK_WEEKS] storage weeksToUnlock = accountData.weeksToUnlock;
        uint32[MAX_LOCK_WEEKS] storage amounts = accountData.lockedAmounts;

        // allocate output array
        lockData = new ITokenLocker.LockData[](length);

        uint256 idx;
        for (; idx < length; idx++) {
            // calculate the unlock week for this lock
            uint256 unlockWeek = weeksToUnlock[idx] + accountWeek;

            if (unlockWeek <= systemWeek) {
                assembly {
                    mstore(lockData, idx)
                }
                break;
            }

            lockData[idx] = ITokenLocker.LockData({amount: amounts[idx], weeksToUnlock: unlockWeek - systemWeek});
        }
    }

    function _registerAccountWeight(address account, uint256 minWeeks) internal returns (uint256 frozen) {
        // get storage reference to account's lock data
        AccountData storage accountData = accountLockData[account];

        ITokenLocker.LockData[] memory lockData;

        // get latest account lock weights from TokenLocker and store locally
        (lockData, frozen) = tokenLocker.getAccountActiveLocks(account, minWeeks);

        // cache number of locks
        uint256 length = lockData.length;

        // if frozen, multiply by max lock weeks and
        // update storage account frozen weight
        if (frozen > 0) {
            frozen *= MAX_LOCK_WEEKS;
            accountData.frozenWeight = SafeCast.toUint40(frozen);
        }
        // else if there are active locks iterate through them
        // updating storage account locked amounts and weeks to unlock
        else if (length > 0) {
            for (uint256 i; i < length; i++) {
                accountData.lockedAmounts[i] = SafeCast.toUint32(lockData[i].amount);
                accountData.weeksToUnlock[i] = SafeCast.toUint8(lockData[i].weeksToUnlock);
            }
        }
        // revert if nothing frozen and no active locks
        else {
            revert("No active locks");
        }

        // get current system week
        uint256 systemWeek = getWeek();

        // update storage account latest processed week to current system
        // week and lock length to latest locks processed from TokenLocker
        accountData.week = SafeCast.toUint16(systemWeek);
        accountData.lockLength = SafeCast.toUint8(length);

        emit AccountWeightRegistered(account, systemWeek, frozen, lockData);
    }

    function _storeAccountVotes(
        address account,
        AccountData storage accountData,
        Vote[] calldata votes,
        uint256 points,
        uint256 offset
    ) internal {
        // get storage reference to account's active votes
        uint16[2][MAX_POINTS] storage storedVotes = accountData.activeVotes;

        // iterate through votes input, cheaper to not
        // cache length since calldata
        for (uint256 i; i < votes.length; i++) {
            // prevent voting for disabled receivers
            require(
                IBimaVault(vault).isReceiverActive(votes[i].id),
                "Can't vote for disabled receivers - clearVote first"
            );

            // record each vote
            storedVotes[offset + i] = [SafeCast.toUint16(votes[i].id), SafeCast.toUint16(votes[i].points)];
            points += votes[i].points;
        }

        require(points <= MAX_POINTS, "Exceeded max vote points");

        accountData.voteLength = SafeCast.toUint16(offset + votes.length);
        accountData.points = SafeCast.toUint16(points);

        emit NewVotes(account, getWeek(), votes, points);
    }

    /**
        @dev Increases receiver and total weights, using a vote array and the
             registered weights of `msg.sender`. Account related values are not
             adjusted, they must be handled in the calling function.
     */
    function _addVoteWeights(address account, Vote[] memory votes, uint256 frozenWeight) internal {
        if (votes.length > 0) {
            if (frozenWeight > 0) {
                _addVoteWeightsFrozen(votes, frozenWeight);
            } else {
                _addVoteWeightsUnfrozen(account, votes);
            }
        }
    }

    /**
        @dev Decreases receiver and total weights, using a vote array and the
             registered weights of `msg.sender`. Account related values are not
             adjusted, they must be handled in the calling function.
     */
    function _removeVoteWeights(address account, Vote[] memory votes, uint256 frozenWeight) internal {
        if (votes.length > 0) {
            if (frozenWeight > 0) {
                _removeVoteWeightsFrozen(votes, frozenWeight);
            } else {
                _removeVoteWeightsUnfrozen(account, votes);
            }
        }
    }

    /** @dev Should not be called directly, use `_addVoteWeights` */
    function _addVoteWeightsUnfrozen(address account, Vote[] memory votes) internal {
        // get account locks from TokenLocker
        ITokenLocker.LockData[] memory lockData = _getAccountLocks(account);

        // cache number of locks
        uint256 lockLength = lockData.length;

        // revert if no locks
        require(lockLength > 0, "Registered weight has expired");

        // working data
        uint256 totalWeight;
        uint256 totalDecay;
        uint256 systemWeek = getWeek();
        uint256[MAX_LOCK_WEEKS + 1] memory weeklyUnlocks;

        // iterate through every vote
        for (uint256 i; i < votes.length; i++) {
            (uint256 id, uint256 points) = (votes[i].id, votes[i].points);

            // working data
            uint256 weight;
            uint256 decayRate;

            // for every vote, iterate through every lock
            for (uint256 x; x < lockLength; x++) {
                uint256 weeksToUnlock = lockData[x].weeksToUnlock;
                uint256 amount = (lockData[x].amount * points) / MAX_POINTS;

                // updating storage receiver weekly unlocks
                receiverWeeklyUnlocks[id][systemWeek + weeksToUnlock] += SafeCast.toUint32(amount);

                // update working data
                weeklyUnlocks[weeksToUnlock] += SafeCast.toUint32(amount);
                weight += amount * weeksToUnlock;
                decayRate += amount;
            }

            // update storage receiver weekly weights and decay rate
            receiverWeeklyWeights[id][systemWeek] = SafeCast.toUint40(getReceiverWeightWrite(id) + weight);
            receiverDecayRate[id] += SafeCast.toUint32(decayRate);

            // update working data
            totalWeight += weight;
            totalDecay += decayRate;
        }

        // iterate through every lock updating storage total weekly unlocks
        for (uint256 i; i < lockLength; i++) {
            uint256 weeksToUnlock = lockData[i].weeksToUnlock;
            totalWeeklyUnlocks[systemWeek + weeksToUnlock] += SafeCast.toUint32(weeklyUnlocks[weeksToUnlock]);
        }

        // update storage total weekly weights and decay rate
        // using working data totals calculated in previous loops
        totalWeeklyWeights[systemWeek] = SafeCast.toUint40(getTotalWeightWrite() + totalWeight);
        totalDecayRate += SafeCast.toUint32(totalDecay);
    }

    /** @dev Should not be called directly, use `_addVoteWeights` */
    function _addVoteWeightsFrozen(Vote[] memory votes, uint256 frozenWeight) internal {
        // get current system week
        uint256 systemWeek = getWeek();

        // working data
        uint256 totalWeight;

        // cache votes length
        uint256 length = votes.length;

        // iterate through every vote
        for (uint256 i; i < length; i++) {
            (uint256 id, uint256 points) = (votes[i].id, votes[i].points);

            uint256 weight = (frozenWeight * points) / MAX_POINTS;

            // trigger receiver weight write to process any missing
            // weeks until system week, then update storage receiver
            // weekly weights
            receiverWeeklyWeights[id][systemWeek] = SafeCast.toUint40(getReceiverWeightWrite(id) + weight);

            // update working data
            totalWeight += weight;
        }

        // trigger total weight write to process any missing weeks until
        // system week, then update storage total weekly weights
        totalWeeklyWeights[systemWeek] = SafeCast.toUint40(getTotalWeightWrite() + totalWeight);
    }

    /** @dev Should not be called directly, use `_removeVoteWeights` */
    function _removeVoteWeightsUnfrozen(address account, Vote[] memory votes) internal {
        // get account locks from TokenLocker
        ITokenLocker.LockData[] memory lockData = _getAccountLocks(account);

        // cache number of locks
        uint256 lockLength = lockData.length;

        // working data
        uint256 totalWeight;
        uint256 totalDecay;
        uint256 systemWeek = getWeek();
        uint256[MAX_LOCK_WEEKS + 1] memory weeklyUnlocks;

        // iterate through every vote
        for (uint256 i; i < votes.length; i++) {
            (uint256 id, uint256 points) = (votes[i].id, votes[i].points);

            // working data
            uint256 weight;
            uint256 decayRate;

            // for every vote, iterate through every lock
            for (uint256 x; x < lockLength; x++) {
                uint256 weeksToUnlock = lockData[x].weeksToUnlock;
                uint256 amount = (lockData[x].amount * points) / MAX_POINTS;

                // updating storage receiver weekly unlocks
                receiverWeeklyUnlocks[id][systemWeek + weeksToUnlock] -= SafeCast.toUint32(amount);

                // update working data
                weeklyUnlocks[weeksToUnlock] += SafeCast.toUint32(amount);
                weight += amount * weeksToUnlock;
                decayRate += amount;
            }

            // update storage receiver weekly weights and decay rate
            receiverWeeklyWeights[id][systemWeek] = SafeCast.toUint40(getReceiverWeightWrite(id) - weight);
            receiverDecayRate[id] -= SafeCast.toUint32(decayRate);

            // update working data
            totalWeight += weight;
            totalDecay += decayRate;
        }

        // iterate through every lock updating storage total weekly unlocks
        for (uint256 i; i < lockLength; i++) {
            uint256 weeksToUnlock = lockData[i].weeksToUnlock;
            totalWeeklyUnlocks[systemWeek + weeksToUnlock] -= SafeCast.toUint32(weeklyUnlocks[weeksToUnlock]);
        }

        // update storage total weekly weights and decay rate
        // using working data totals calculated in previous loops
        totalWeeklyWeights[systemWeek] = SafeCast.toUint40(getTotalWeightWrite() - totalWeight);
        totalDecayRate -= SafeCast.toUint32(totalDecay);
    }

    /** @dev Should not be called directly, use `_removeVoteWeights` */
    function _removeVoteWeightsFrozen(Vote[] memory votes, uint256 frozenWeight) internal {
        // get current system week
        uint256 systemWeek = getWeek();

        // working data
        uint256 totalWeight;

        // cache votes length
        uint256 length = votes.length;

        // iterate through every vote
        for (uint256 i; i < length; i++) {
            (uint256 id, uint256 points) = (votes[i].id, votes[i].points);

            uint256 weight = (frozenWeight * points) / MAX_POINTS;

            // trigger receiver weight write to process any missing
            // weeks until system week, then update storage receiver
            // weekly weights
            receiverWeeklyWeights[id][systemWeek] = SafeCast.toUint40(getReceiverWeightWrite(id) - weight);

            // update working data
            totalWeight += weight;
        }

        // trigger total weight write to process any missing weeks until
        // system week, then update storage total weekly weights
        totalWeeklyWeights[systemWeek] = SafeCast.toUint40(getTotalWeightWrite() - totalWeight);
    }
}
