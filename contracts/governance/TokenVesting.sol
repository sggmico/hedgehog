// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenVesting
 * @notice HEDGE 代币锁仓合约 (cliff + 线性释放)
 * @dev 用于团队、顾问和早期投资者的代币锁仓
 *
 * 锁仓计划:
 * - 团队/顾问: 4 年锁仓 (1 年 cliff, 后续 3 年线性释放)
 * - 早期投资者: 2 年锁仓 (6 个月 cliff, 后续 18 个月线性释放)
 */
contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // 锁仓计划
    struct VestingSchedule {
        uint256 totalAmount;      // 总锁仓量
        uint256 releasedAmount;   // 已释放量
        uint256 startTime;        // 开始时间
        uint256 cliffDuration;    // Cliff 期限 (秒)
        uint256 vestingDuration;  // 总锁仓期限 (秒, 含 cliff)
        bool revocable;           // 是否可撤销
        bool revoked;             // 是否已撤销
    }

    // HEDGE 代币合约
    IERC20 public immutable hedgeToken;

    // 受益人 => 锁仓计划
    mapping(address => VestingSchedule) public vestingSchedules;

    // 总锁仓量
    uint256 public totalVestedAmount;

    // 事件
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 refundAmount);

    // 错误
    error ZeroAddress();
    error ZeroAmount();
    error VestingAlreadyExists();
    error NoVestingSchedule();
    error NoTokensToRelease();
    error NotRevocable();
    error AlreadyRevoked();
    error InsufficientBalance();
    error InvalidDuration();

    constructor(address _hedgeToken) Ownable(msg.sender) {
        if (_hedgeToken == address(0)) revert ZeroAddress();
        hedgeToken = IERC20(_hedgeToken);
    }

    /**
     * @notice 创建锁仓计划
     * @param beneficiary 受益人地址
     * @param amount 锁仓总量
     * @param startTime 开始时间 (0 = 当前时间)
     * @param cliffDuration Cliff 期限 (秒)
     * @param vestingDuration 总锁仓期限 (秒, 含 cliff)
     * @param revocable 是否可撤销
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable
    ) external onlyOwner {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (vestingSchedules[beneficiary].totalAmount > 0) revert VestingAlreadyExists();
        if (vestingDuration == 0 || cliffDuration >= vestingDuration) revert InvalidDuration();

        uint256 actualStartTime = startTime == 0 ? block.timestamp : startTime;

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            releasedAmount: 0,
            startTime: actualStartTime,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            revocable: revocable,
            revoked: false
        });

        totalVestedAmount += amount;

        // 从 owner 转入代币
        hedgeToken.safeTransferFrom(msg.sender, address(this), amount);

        emit VestingScheduleCreated(
            beneficiary,
            amount,
            actualStartTime,
            cliffDuration,
            vestingDuration
        );
    }

    /**
     * @notice 受益人领取已释放的代币
     */
    function release() external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (schedule.totalAmount == 0) revert NoVestingSchedule();
        if (schedule.revoked) revert AlreadyRevoked();

        uint256 releasableAmount = _computeReleasableAmount(schedule);
        if (releasableAmount == 0) revert NoTokensToRelease();

        schedule.releasedAmount += releasableAmount;
        hedgeToken.safeTransfer(msg.sender, releasableAmount);

        emit TokensReleased(msg.sender, releasableAmount);
    }

    /**
     * @notice 撤销锁仓计划，归还未释放代币给 owner
     * @param beneficiary 受益人地址
     */
    function revoke(address beneficiary) external onlyOwner {
        VestingSchedule storage schedule = vestingSchedules[beneficiary];
        if (schedule.totalAmount == 0) revert NoVestingSchedule();
        if (!schedule.revocable) revert NotRevocable();
        if (schedule.revoked) revert AlreadyRevoked();

        // 计算已释放量
        uint256 vestedAmount = _computeVestedAmount(schedule);
        uint256 releasableAmount = vestedAmount - schedule.releasedAmount;

        // 标记为已撤销
        schedule.revoked = true;

        // 计算退款 (总量 - 已释放)
        uint256 refundAmount = schedule.totalAmount - vestedAmount;
        totalVestedAmount -= refundAmount;

        // 释放已解锁的代币给受益人
        if (releasableAmount > 0) {
            schedule.releasedAmount += releasableAmount;
            hedgeToken.safeTransfer(beneficiary, releasableAmount);
        }

        // 归还未释放代币给 owner
        if (refundAmount > 0) {
            hedgeToken.safeTransfer(owner(), refundAmount);
        }

        emit VestingRevoked(beneficiary, refundAmount);
    }

    /**
     * @notice 查询受益人可领取的代币量
     * @param beneficiary 受益人地址
     */
    function getReleasableAmount(address beneficiary) external view returns (uint256) {
        return _computeReleasableAmount(vestingSchedules[beneficiary]);
    }

    /**
     * @notice 查询受益人已释放的代币量
     * @param beneficiary 受益人地址
     */
    function getVestedAmount(address beneficiary) external view returns (uint256) {
        return _computeVestedAmount(vestingSchedules[beneficiary]);
    }

    /**
     * @notice 紧急提取非锁仓代币
     * @param token 代币地址
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(hedgeToken)) {
            uint256 available = hedgeToken.balanceOf(address(this)) - totalVestedAmount;
            if (amount > available) revert InsufficientBalance();
        }
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ============ 内部函数 ============

    /**
     * @dev 计算可领取量
     */
    function _computeReleasableAmount(VestingSchedule memory schedule)
        private
        view
        returns (uint256)
    {
        return _computeVestedAmount(schedule) - schedule.releasedAmount;
    }

    /**
     * @dev 计算已释放量
     */
    function _computeVestedAmount(VestingSchedule memory schedule)
        private
        view
        returns (uint256)
    {
        if (schedule.totalAmount == 0) return 0;

        // Cliff 期内: 不释放
        if (block.timestamp < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }

        // 锁仓期结束: 全部释放
        if (block.timestamp >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount;
        }

        // Cliff 后线性释放
        uint256 timeFromStart = block.timestamp - schedule.startTime;
        return (schedule.totalAmount * timeFromStart) / schedule.vestingDuration;
    }
}
