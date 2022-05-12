// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPanicChef} from "./interfaces/IPanicChef.sol";
import {IPanicMinter} from "./interfaces/IPanicMinter.sol";
import {IBeetsChef} from "./interfaces/IBeetsChef.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {TokenMintable} from "./TokenMintable.sol";

contract BeetsProxyFarmer is Ownable {
    using SafeTransferLib for IERC20;

    constructor() {
        DUMMY_TOKEN = new TokenMintable();

        // We can safely max approve BeethovenX's MasterChef as it has been
        // audited and battle-tested. We will also never reach this max amount.
        LP_TOKEN.safeApprove(address(BEETS_CHEF), type(uint256).max);
    }

    /// @notice Packed storage slot. Saves gas on read.
    struct Slot0 {
        bool rewardsActive;     // Whether or not rewards are active on the farmer.
        uint8 targetPoolId;     // Target pool ID to stake the dummy token into.
        uint8 targetBeetsPoolId;    // Target BeethovenX pool ID to stake into.
        uint32 tLastRewardUpdate;   // Time of the last PANIC reward update on the farm.
        uint64 panicRate;           // Amount of PANIC distributed per second.
        uint112 panicPerShare;      // Amount of PANIC rewards per share in the farm.
        // This totals at 29 bytes, allowing this to all be packed into one 32 byte storage slot. Significant gas savings.
    }

    /// @notice User info. Packed into one storage slot.
    struct UserSlot {
        uint112 stakedAmount;
        uint112 rewardDebt;
        // This also totals at 28 bytes, making this all readable in one 32 byte slot.
    }

    /// @notice Internal balances for tracking LP tokens.
    struct InternalBalance {
        uint112 internalBalanceOf;
        uint112 internalStake;
    }

    /// @notice Dummy token used for farming PANIC.
    TokenMintable public immutable DUMMY_TOKEN;

    /// @notice LP token to deposit into the contract.
    IERC20 public constant LP_TOKEN = IERC20(0x1E2576344D49779BdBb71b1B76193d27e6F996b7);

    /// @notice PANIC token contract.
    IERC20 public constant PANIC = IERC20(0xA882CeAC81B22FC2bEF8E1A82e823e3E9603310B);

    /// @notice BEETS token contract.
    IERC20 public constant BEETS = IERC20(0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e);

    /// @notice Panicswap MasterChef contract.
    IPanicChef public constant PANIC_CHEF = IPanicChef(0xC02563f20Ba3e91E459299C3AC1f70724272D618);

    /// @notice Panicswap PANIC minter contract.
    IPanicMinter public constant PANIC_MINTER = IPanicMinter(0x536b88CC4Aa42450aaB021738bf22D63DDC7303e);

    /// @notice BeethovenX MasterChef contract.
    IBeetsChef public constant BEETS_CHEF = IBeetsChef(0x8166994d9ebBe5829EC86Bd81258149B87faCfd3);

    /// @notice Storage slot #0. Multiple values packed into one.
    Slot0 public slot0;

    /// @notice Storage slot for tracking farm info.
    InternalBalance public internalBalance;

    /// @notice Internal tracking for deposited tokens.
    uint256 public nTokensDeposited;

    /// @notice Data for a specific user.
    mapping(address => UserSlot) public userSlot;

    /// @notice Emitted on a deposit on the farmer.
    event Deposit(address indexed depositor, uint256 amount);

    /// @notice Emitted on a withdrawal on the farmer.
    event Withdrawal(address indexed depositor, uint256 amount);

    /// @notice Deposits tokens into the farmer.
    /// @param _amount Amount of tokens to deposit.
    function deposit(uint256 _amount) external {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];

        // Update reward variables.
        _slot0 = _updateRewards(_slot0);

        // Claim any pending PANIC.
        uint112 newDebt;
        if(_userSlot.stakedAmount > 0) {
            panicHarvest(); // To save gas for the user, we only do this if they *potentially* have rewards.
            newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
            PANIC.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);
        }

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount = uint112(_amount);
        _userSlot.rewardDebt += newDebt;
        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited += _amount;

        // Transfer tokens in and stake into BeethovenX.
        LP_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
        BEETS_CHEF.deposit(_slot0.targetBeetsPoolId, _amount, address(this));
        internalBalance.internalStake += uint112(_amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraws tokens from the farmer.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) external {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];
        require(_userSlot.stakedAmount >= _amount, "Cannot withdraw over stake");

        // Update reward variables.
        _slot0 = _updateRewards(_slot0);

        // Claim any pending PANIC.
        panicHarvest();
        uint112 newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
        PANIC.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount -= uint112(_amount);
        _userSlot.rewardDebt += newDebt;
        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited -= uint112(_amount);

        // Transfer tokens out.
        InternalBalance memory _internalBalance = internalBalance;
        if(_amount > _internalBalance.internalBalanceOf) {
            try BEETS_CHEF.withdrawAndHarvest(_slot0.targetBeetsPoolId, _amount, address(this)) {
                LP_TOKEN.safeTransfer(msg.sender, _amount);
                _internalBalance.internalStake -= uint112(_amount);
                internalBalance = _internalBalance;
            } catch {
                BEETS_CHEF.emergencyWithdraw(_slot0.targetBeetsPoolId, address(this));
                LP_TOKEN.safeTransfer(msg.sender, _amount);
                _internalBalance.internalBalanceOf = uint112(_internalBalance.internalStake - _amount);
                _internalBalance.internalStake = 0;
                internalBalance = _internalBalance;
            }
        } else {
            LP_TOKEN.safeTransfer(msg.sender, _amount);
        }
        emit Withdrawal(msg.sender, _amount);
    }

    /// @notice Claims PANIC tokens from the farm.
    function claim() external {
        panicHarvest();
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];

        // A user wouldn't have claimable rewards if they exited.
        uint112 newDebt;
        if(_userSlot.stakedAmount > 0) {
            newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
            PANIC.safeTransfer(msg.sender, newDebt = _userSlot.rewardDebt);
        }

        // Update stored values.
        _userSlot.rewardDebt += newDebt;
        userSlot[msg.sender] = _userSlot;
    }

    /// @notice Harvests BEETS tokens from BeethovenX.
    function harvestBeets() external {
        BEETS_CHEF.harvest(slot0.targetBeetsPoolId, address(this));
        BEETS.safeTransfer(owner(), BEETS.balanceOf(address(this)));
    }

    /// @notice Harvests PANIC tokens from Panicswap's MasterChef.
    function panicHarvest() public {
        uint256[] memory _pids = new uint256[](1);
        _pids[0] = slot0.targetPoolId;
        PANIC_CHEF.claim(_pids);
        PANIC_MINTER.exit();
    }

    /// @notice Updates the PANIC reward rate.
    function updatePanicRate() public {
        Slot0 memory _slot0 = slot0;

        // Update rewards.
        _slot0 = _updateRewards(_slot0);

        // Recalculate the rate.
        IPanicChef.PoolInfo memory _info = PANIC_CHEF.poolInfo(_slot0.targetPoolId);
        if(_info.allocPoint == 0) {
            _slot0.rewardsActive = false;
            _slot0.panicRate = 0;
        } else {
            _slot0.panicRate = uint64(((PANIC_CHEF.rewardsPerSecond() * (_info.allocPoint)) / PANIC_CHEF.totalAllocPoint()) / 2);
        }

        // Write to slot0.
        slot0 = _slot0;
    }

    /// @notice Sets the farming pool IDs and begins emissions.
    /// @param _panicId Panicswap pool ID to deposit into.
    /// @param _beetsId BeethovenX pool ID to deposit into.
    function setPoolIDsAndEmit(
        uint8 _panicId,
        uint8 _beetsId
    ) public onlyOwner {
        Slot0 memory _slot0 = slot0;
        require(_slot0.targetPoolId == 0 && _slot0.targetBeetsPoolId == 0, "IDs already set");
        
        // Create all writes in memory.
        _slot0.rewardsActive = true;
        _slot0.targetPoolId = _panicId;
        _slot0.targetBeetsPoolId = _beetsId;
        _slot0.tLastRewardUpdate = uint32(block.timestamp);
        IPanicChef.PoolInfo memory _info = PANIC_CHEF.poolInfo(_panicId);
        _slot0.panicRate = uint64(((PANIC_CHEF.rewardsPerSecond() * (_info.allocPoint)) / PANIC_CHEF.totalAllocPoint()) / 2);

        // Push memory version of Slot0 to storage.
        slot0 = _slot0;

        // Deposit dummy token into Panicswap's MasterChef.
        DUMMY_TOKEN.approve(address(PANIC_CHEF), 1e18);
        PANIC_CHEF.deposit(_panicId, 1e18);
    }

    /// @notice Performs an emergency exit from BeethovenX.
    function emergencyExitFromBeets() public onlyOwner {
        InternalBalance memory _internalBalance = internalBalance;

        // Withdraw from the chef.
        BEETS_CHEF.emergencyWithdraw(slot0.targetBeetsPoolId, address(this));

        // Update internal balances.
        _internalBalance.internalBalanceOf = _internalBalance.internalStake;
        _internalBalance.internalStake = 0;

        // Update storage.
        internalBalance = _internalBalance;
    }

    function _updateRewards(Slot0 memory _slot0) private view returns (Slot0 memory) {
        uint256 _nTokensDeposited = nTokensDeposited;
        if(block.timestamp <= _slot0.tLastRewardUpdate || _slot0.rewardsActive == false) {
            return _slot0;
        }

        // Do not distribute if there are no deposits.
        if(_nTokensDeposited == 0) {
            _slot0.tLastRewardUpdate = uint32(block.timestamp);
            return _slot0;
        }

        // Distribute new rewards.
        _slot0.panicPerShare += uint112((((block.timestamp - _slot0.tLastRewardUpdate) * _slot0.panicRate) * 1e12) / _nTokensDeposited);
        _slot0.tLastRewardUpdate = uint32(block.timestamp);

        // Return new slot.
        return _slot0;
    }
}