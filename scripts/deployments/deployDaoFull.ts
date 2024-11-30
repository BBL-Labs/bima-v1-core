import { BaseContract, ContractFactory } from "ethers";
import { ethers } from "hardhat";

// Contract Addresses
const BIMACORE_ADDRESS = ""; //! IMPORTANT
const BIMATOKEN_ADDRESS = ""; //! IMPORTANT
const TOKENLOCKER_ADDRESS = ""; //! IMPORTANT
const TOKENVAULT_ADDRESS = ""; //! IMPORTANT
const INCENTIVEVOTING_ADDRESS = ""; //! IMPORTANT

// ? Boost Calculator
// BS_GRACE_WEEKS after which the boost will start
const BS_GRACE_WEEKS = BigInt("5"); //!

// ? Emission Schedule
// Earned BIMA continues to be locked upon claiming, starting at INITIAL_LOCK_WEEKS weeks locking.
// The number of weeks of the lock decreases by 1 every LOCK_DECAY_WEEKS weeks,
// eventually reaching 0. It is possible to exit a locked position early by paying a withdrawal fee.
// Each week, WEEKLY_PCT of total unallocated BIMA is available for emissions.
// SCHEDULED_WEEKLY_PCT contains any future changes to that percentage.
const INITIAL_LOCK_WEEKS_ES = BigInt("5"); //!
const LOCK_DECAY_WEEKS = BigInt("2"); //!
const WEEKLY_PCT = BigInt("80"); //!
const SCHEDULED_WEEKLY_PCT = [
    [BigInt("25"), BigInt("5000")], // 50% after 37 weeks
    [BigInt("10"), BigInt("6000")], // 60% after 12 weeks
    [BigInt("2"), BigInt("7000")], // 70% after 2 weeks
]; //!

// ? Token Vault
const TOTAL_SUPPLY = ethers.parseUnits("500000000", 18); // 500 Million BIMA
const INITIAL_LOCK_WEEKS_TV = INITIAL_LOCK_WEEKS_ES;
const FIXED_INITIAL_AMOUNTS: any = [];
const INITIAL_ALLOWANCES = [{ receiver: "0x", amount: ethers.parseUnits("100", 18) }];

// ? Token Locker
// ALLOW_PENALTY_WITHDRAW_AFTER must be greate than now and less than 13 weeks in the future
const ALLOW_PENALTY_WITHDRAW_AFTER = BigInt("1738368000"); // Saturday, February 1, 2025 12:00:00 AM GMT

// ? Admin Voting
const MIN_CREATE_PROPOSAL_PCT = BigInt("500"); //! 5%
const PASSING_PCT = BigInt("5000"); //! 50%

async function deployDaoFull() {
    const [owner] = await ethers.getSigners();

    const factories = await getFactories();

    const bimaToken = await ethers.getContractAt("BimaToken", BIMATOKEN_ADDRESS);
    const tokenLocker = await ethers.getContractAt("TokenLocker", TOKENLOCKER_ADDRESS);
    const tokenVault = await ethers.getContractAt("TokenVault", TOKENVAULT_ADDRESS);

    const [, deployedBoostCalculatorAddress] = await deployContract(
        factories.BoostCalculator,
        "BoostCalculator",
        BIMACORE_ADDRESS,
        TOKENLOCKER_ADDRESS,
        BS_GRACE_WEEKS
    );
    const [, deployedEmissionScheduleAddress] = await deployContract(
        factories.EmissionSchedule,
        "EmissionSchedule",
        BIMACORE_ADDRESS,
        INCENTIVEVOTING_ADDRESS,
        TOKENVAULT_ADDRESS,
        INITIAL_LOCK_WEEKS_ES,
        LOCK_DECAY_WEEKS,
        WEEKLY_PCT,
        SCHEDULED_WEEKLY_PCT
    );

    {
        const tx = await tokenVault.setInitialParameters(
            deployedEmissionScheduleAddress,
            deployedBoostCalculatorAddress,
            TOTAL_SUPPLY,
            INITIAL_LOCK_WEEKS_TV,
            FIXED_INITIAL_AMOUNTS,
            INITIAL_ALLOWANCES
        );
        await tx.wait();
        console.log("-- tx: tokenVault.setInitialParameters");
    }

    {
        const tx = await tokenLocker.setAllowPenaltyWithdrawAfter(ALLOW_PENALTY_WITHDRAW_AFTER);
        await tx.wait();
        console.log("-- tx: tokenLocker.setAllowPenaltyWithdrawAfter");
    }

    const [, ,] = await deployContract(
        factories.AdminVoting,
        "AdminVoting",
        BIMACORE_ADDRESS,
        TOKENLOCKER_ADDRESS,
        MIN_CREATE_PROPOSAL_PCT,
        PASSING_PCT
    );
}

deployDaoFull()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

const getFactories = async () => ({
    AdminVoting: await ethers.getContractFactory("AdminVoting"),
    AirdropDistributor: await ethers.getContractFactory("AirdropDistributor"),
    AllocationVesting: await ethers.getContractFactory("AllocationVesting"),
    BoostCalculator: await ethers.getContractFactory("BoostCalculator"),
    EmissionSchedule: await ethers.getContractFactory("EmissionSchedule"),
});

const deployContract = async (
    deployer: ContractFactory,
    contractName: string,
    ...args: any[]
): Promise<[BaseContract, string]> => {
    const contract = await deployer.deploy(...args);
    await contract.waitForDeployment();
    const address = await contract.getAddress();
    console.log(`${contractName} deployed!: `, address);
    return [contract, address];
};

const assertEq = (a: string, b: string) => {
    if (a !== b) throw new Error(`Expected ${a} to equal ${b}`);
};
