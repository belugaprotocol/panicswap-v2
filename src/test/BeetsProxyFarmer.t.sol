// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {DSTest} from "ds-test/test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPanicChef} from "../interfaces/IPanicChef.sol";
import {IHevm} from "./utils/IHevm.sol";
import {BeetsProxyFarmer} from "../BeetsProxyFarmer.sol";

/// @title Beets Proxy Farmer Test
/// @author Chainvisions
/// @notice Tests for Panicswap's BeethovenX proxy farmer.

contract BeetsProxyFarmerTest is DSTest {

    /// @notice HEVM contract for manipulating the network via cheatcodes.
    IHevm public constant HEVM = IHevm(HEVM_ADDRESS);

    /// @notice PANIC token contract.
    IERC20 public constant PANIC = IERC20(0xA882CeAC81B22FC2bEF8E1A82e823e3E9603310B);

    /// @notice Never Panic Yearn Boosted token contract.
    IERC20 public constant NEVER_PANIC = IERC20(0x1E2576344D49779BdBb71b1B76193d27e6F996b7);

    /// @notice Never Panic BPT whale.
    address public constant WHALE = 0x1B5b5FB19d0a398499A9694AD823D786c24804CC;

    /// @notice Panicswap governance address.
    address public constant GOV = 0xb1eAfc8C60f68646F4EFbd3806875fE468933749;

    /// @notice Panicswap MasterChef contract.
    IPanicChef public constant PANIC_CHEF = IPanicChef(0xC02563f20Ba3e91E459299C3AC1f70724272D618);

    /// @notice BeethovenX proxy farmer contract.
    BeetsProxyFarmer public proxyFarmer;

    /// @notice Sets up the testing suite.
    function setUp() public {
        HEVM.startPrank(GOV, GOV);
        proxyFarmer = new BeetsProxyFarmer();
        PANIC_CHEF.addPool(address(proxyFarmer.dummyToken()), 5000, true);
        proxyFarmer.setPoolIDsAndEmit(23);
        HEVM.stopPrank();
    }

    /// @notice Tests a deposit on the proxy farmer.
    function testDepositShouldSucceed() public {
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);
        HEVM.stopPrank();

        // Check stake.
        (uint256 stake, ) = proxyFarmer.userSlot(WHALE);
        assertEq(stake, balance);
    }

    /// @notice Tests a withdrawal on the proxy farmer.
    function testWithdrawShouldSucceed() public {
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);

        HEVM.warp(block.timestamp + 6969); // We assume they withdraw later.

        // Perform withdrawal and check balance.
        proxyFarmer.withdraw(balance);
        assertEq(NEVER_PANIC.balanceOf(WHALE), balance);
    }

    /// @notice Tests that a withdrawal fails if it is above the staked amount.
    function testWithdrawShouldFailAboveStake() public {
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);

        // Attempt withdrawal.
        HEVM.expectRevert(bytes("Cannot withdraw over stake"));
        proxyFarmer.withdraw(balance * 2);
    }

    /// @notice Tests an emergency withdrawal on the proxy farmer.
    function testEmergencyWithdraw() public {
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);

        // Perform withdrawal and check balance.
        proxyFarmer.emergencyWithdraw();
        assertEq(NEVER_PANIC.balanceOf(WHALE), balance);
    }

    /// @notice Fuzzed test on proxy farm deposits.
    /// @param _amount Amount to test a deposit with.
    function testDepositFuzzed(uint256 _amount) public {
        // Set assumptions
        uint256 whaleBalance = NEVER_PANIC.balanceOf(WHALE);
        HEVM.assume(_amount <= whaleBalance);

        // Start prank and deposit.
        HEVM.startPrank(WHALE, WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), _amount);
        proxyFarmer.deposit(_amount);
    }

    /// @notice Fuzzed test on proxy farm withdrawals.
    /// @param _amount Amount to test a withdrawal with.
    function testWithdrawFuzzed(uint256 _amount) public {
        // Set assumptions
        uint256 whaleBalance = NEVER_PANIC.balanceOf(WHALE);
        HEVM.assume(_amount <= whaleBalance);

        // Start prank and deposit.
        HEVM.startPrank(WHALE, WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), _amount);
        proxyFarmer.deposit(_amount);

        // Withdraw the same amount.
        proxyFarmer.withdraw(_amount);
    }

    /// @notice Tests that the calculated PANIC is accurate.
    function testRateShouldBeAccurate() public {
        uint256 rate = proxyFarmer.panicRate();
        emit log_uint(rate);
        assertGt(rate, 0);
    }

    /// @notice Tests that rewards are generated properly on the farm.
    function testWarpExactRewards() public {
        uint256 startBalance = PANIC.balanceOf(WHALE);
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);

        // Warp and claim rewards.
        HEVM.warp(block.timestamp + 300);
        proxyFarmer.claim();

        uint256 claimed = PANIC.balanceOf(WHALE) - startBalance;
        assertGt(claimed, 0);
    }

    /// @notice Tests that rewards are not double dipped.
    function testShouldNotDoubleDip() public {
        uint256 startBalance = PANIC.balanceOf(WHALE);
        HEVM.startPrank(WHALE, WHALE);

        // Perform deposit.
        uint256 balance = NEVER_PANIC.balanceOf(WHALE);
        NEVER_PANIC.approve(address(proxyFarmer), balance);
        proxyFarmer.deposit(balance);

        // Warp and claim rewards.
        HEVM.warp(block.timestamp + 300);
        proxyFarmer.claim();
        uint256 claimed = PANIC.balanceOf(WHALE) - startBalance;

        // Perform another warp & claim.
        HEVM.warp(block.timestamp + 150);
        proxyFarmer.claim();
        uint256 latestClaimed = (PANIC.balanceOf(WHALE) - startBalance) - claimed;
        emit log_named_uint("First claim: ", claimed);
        emit log_named_uint("Second claim: ", latestClaimed);
        assertLt(latestClaimed, claimed);
    }
}