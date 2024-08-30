// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IEmissionSchedule, IIncentiveVoting, IBabelVault} from "../interfaces/IEmissionSchedule.sol";
import {BabelOwnable} from "../dependencies/BabelOwnable.sol";
import {SystemStart} from "../dependencies/SystemStart.sol";

/**
    @title Babel Emission Schedule
    @notice Calculates weekly BABEL emissions. The weekly amount is determined
            as a percentage of the remaining unallocated supply. Over time the
            reward rate will decay to dust as it approaches the maximum supply,
            but should not reach zero for a Very Long Time.
 */
contract EmissionSchedule is IEmissionSchedule, BabelOwnable, SystemStart {
    // number representing 100% in `weeklyPct`
    uint256 constant MAX_PCT = 10000;
    uint256 public constant MAX_LOCK_WEEKS = 52;

    IIncentiveVoting public immutable voter;
    IBabelVault public immutable vault;

    // current number of weeks that emissions are locked for when they are claimed
    uint64 public lockWeeks;
    // every `lockDecayWeeks`, the number of lock weeks is decreased by one
    uint64 public lockDecayWeeks;

    // percentage of the unallocated BABEL supply given as emissions in a week
    uint64 public weeklyPct;

    // [(week, weeklyPct)... ] ordered by week descending
    // schedule of changes to `weeklyPct` to be applied in future weeks
    uint64[2][] private scheduledWeeklyPct;

    constructor(
        address _babelCore,
        IIncentiveVoting _voter,
        IBabelVault _vault,
        uint64 _initialLockWeeks,
        uint64 _lockDecayWeeks,
        uint64 _weeklyPct,
        uint64[2][] memory _scheduledWeeklyPct
    ) BabelOwnable(_babelCore) SystemStart(_babelCore) {
        voter = _voter;
        vault = _vault;

        lockWeeks = _initialLockWeeks;
        lockDecayWeeks = _lockDecayWeeks;
        weeklyPct = _weeklyPct;
        _setWeeklyPctSchedule(_scheduledWeeklyPct);
        emit LockParametersSet(_initialLockWeeks, _lockDecayWeeks);
    }

    function getWeeklyPctSchedule() external view returns (uint64[2][] memory) {
        return scheduledWeeklyPct;
    }

    /**
        @notice Set a schedule for future updates to `weeklyPct`
        @dev The given schedule replaces any existing one
        @param _schedule Dynamic array of (week, weeklyPct) ordered by week descending.
                         Each `week` indicates the number of weeks after the current week.
     */
    function setWeeklyPctSchedule(uint64[2][] calldata _schedule) external onlyOwner returns (bool) {
        _setWeeklyPctSchedule(_schedule);
        return true;
    }

    /**
        @notice Set the number of lock weeks and rate at which lock weeks decay
     */
    function setLockParameters(uint64 _lockWeeks, uint64 _lockDecayWeeks) external onlyOwner returns (bool) {
        // enforce max number of lock weeks
        require(_lockWeeks <= MAX_LOCK_WEEKS, "Cannot exceed MAX_LOCK_WEEKS");

        // enforce positive decay rate
        require(_lockDecayWeeks > 0, "Decay weeks cannot be 0");

        // update storage
        lockWeeks = _lockWeeks;
        lockDecayWeeks = _lockDecayWeeks;

        emit LockParametersSet(_lockWeeks, _lockDecayWeeks);
        return true;
    }

    function getReceiverWeeklyEmissions(
        uint256 id,
        uint256 week,
        uint256 totalWeeklyEmissions
    ) external returns (uint256) {
        uint256 pct = voter.getReceiverVotePct(id, week);

        return (totalWeeklyEmissions * pct) / 1e18;
    }

    function getTotalWeeklyEmissions(
        uint256 week,
        uint256 unallocatedTotal
    ) external returns (uint256 amount, uint64 lock) {
        // only vault can call this function
        require(msg.sender == address(vault));

        // apply the lock week decay
        //
        // output curret weeks to lock for        
        lock = lockWeeks;

        // if current weeks to lock for > 0 AND
        // this week is a decay week
        if (lock > 0 && week % lockDecayWeeks == 0) {
            // then decrement current weeks to lock for
            lock -= 1;
            lockWeeks = lock;

            // note: checks inside `BabelVault::_allocateTotalWeekly`
            // prevent this function being called multiple times
            // for the same week
        }

        // check for and apply scheduled update to `weeklyPct`
        //
        // get number of remaining scheduled weeklyPct updates
        uint256 length = scheduledWeeklyPct.length;

        // get current weeklyPct
        uint256 pct = weeklyPct;

        // if there are remaining scheduled weeklyPct updates
        if (length > 0) {
            // read next update from storage
            uint64[2] memory nextUpdate = scheduledWeeklyPct[length - 1];

            // if the update is for this week
            if (nextUpdate[0] == week) {
                // remove the update from storage
                scheduledWeeklyPct.pop();

                // update the current weeklyPct
                pct = nextUpdate[1];
                weeklyPct = nextUpdate[1];
            }
        }

        // calculate the weekly emissions as a percentage of the unallocated supply
        amount = (unallocatedTotal * pct) / MAX_PCT;
    }

    function _setWeeklyPctSchedule(uint64[2][] memory _scheduledWeeklyPct) internal {
        // _scheduledWeeklyPct
        // first parameter  : number of weeks from now, must be descending and unique
        // second parameter : % of unallocated BABEL supply to be emitted in that week

        // cache length
        uint256 length = _scheduledWeeklyPct.length;

        if (length > 0) {
            // read week from first input element
            uint256 week = _scheduledWeeklyPct[0][0];

            // get the current week protocol is in
            uint256 currentWeek = getWeek();

            for (uint256 i; i < length; i++) {
                // for all subsequent week inputs, enforce descending and unique week
                if (i > 0) {
                    require(_scheduledWeeklyPct[i][0] < week, "Must sort by week descending");
                    week = _scheduledWeeklyPct[i][0];
                }

                // add current week number to input week offset to get actual week
                // number when emissions will occur
                _scheduledWeeklyPct[i][0] = uint64(week + currentWeek);

                // enforce maximum 100% distribution of remaining supply 
                require(_scheduledWeeklyPct[i][1] <= MAX_PCT, "Cannot exceed MAX_PCT");
            }

            // enforce week inputs as number of weeks from current week (ie > 0)
            require(week > 0, "Cannot schedule past weeks");
        }

        // update storage
        scheduledWeeklyPct = _scheduledWeeklyPct;
        
        emit WeeklyPctScheduleSet(_scheduledWeeklyPct);
    }
}
