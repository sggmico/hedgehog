// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title HedgehogToken
 * @notice HEDGE 治理代币
 * @dev ERC20 代币特性:
 * - 固定供应量 10 亿
 * - 投票治理 (ERC20Votes)
 * - 可燃烧
 * - 紧急暂停
 * - 角色权限控制
 *
 * 代币分配 (总量 10 亿):
 * - 40% (4 亿) 社区激励 (流动性挖矿、交易奖励)
 * - 20% (2 亿) 团队/顾问 (4 年锁仓)
 * - 15% (1.5 亿) 早期投资者 (2 年锁仓)
 * - 15% (1.5 亿) DAO 金库
 * - 10% (1 亿) 公开销售
 */
contract HedgehogToken is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    AccessControl,
    ERC20Votes
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // 总供应量: 10 亿 (18 位小数)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;

    // 分配地址 (不可变)
    address public immutable communityIncentives;  // 社区激励
    address public immutable teamAndAdvisors;      // 团队/顾问
    address public immutable earlyInvestors;       // 早期投资者
    address public immutable daoTreasury;          // DAO 金库
    address public immutable publicSale;           // 公开销售

    // 分配数量
    uint256 public constant COMMUNITY_ALLOCATION = 400_000_000 * 10**18; // 40%
    uint256 public constant TEAM_ALLOCATION = 200_000_000 * 10**18;      // 20%
    uint256 public constant INVESTOR_ALLOCATION = 150_000_000 * 10**18;  // 15%
    uint256 public constant DAO_ALLOCATION = 150_000_000 * 10**18;       // 15%
    uint256 public constant PUBLIC_ALLOCATION = 100_000_000 * 10**18;    // 10%

    // 事件
    event TokensDistributed(address indexed recipient, uint256 amount, string allocation);

    // 错误
    error MaxSupplyExceeded();
    error ZeroAddress();

    /**
     * @notice 构造函数 - 初始化代币并分配
     * @param _communityIncentives 社区激励地址
     * @param _teamAndAdvisors 团队/顾问地址 (需配合锁仓)
     * @param _earlyInvestors 早期投资者地址 (需配合锁仓)
     * @param _daoTreasury DAO 金库地址
     * @param _publicSale 公开销售地址
     */
    constructor(
        address _communityIncentives,
        address _teamAndAdvisors,
        address _earlyInvestors,
        address _daoTreasury,
        address _publicSale
    )
        ERC20("Hedgehog", "HEDGE")
        EIP712("Hedgehog", "1")
    {
        if (
            _communityIncentives == address(0) ||
            _teamAndAdvisors == address(0) ||
            _earlyInvestors == address(0) ||
            _daoTreasury == address(0) ||
            _publicSale == address(0)
        ) revert ZeroAddress();

        // 授予角色
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        // 设置分配地址
        communityIncentives = _communityIncentives;
        teamAndAdvisors = _teamAndAdvisors;
        earlyInvestors = _earlyInvestors;
        daoTreasury = _daoTreasury;
        publicSale = _publicSale;

        // 铸造初始分配
        _distributeTokens();
    }

    /**
     * @notice 暂停转账 (仅紧急情况)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice 恢复转账
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice 铸造新代币 (仅紧急情况)
     * @param to 接收地址
     * @param amount 铸造数量
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    // ============ 内部函数 ============

    /**
     * @dev 分配代币到各地址
     */
    function _distributeTokens() private {
        _mint(communityIncentives, COMMUNITY_ALLOCATION);
        emit TokensDistributed(communityIncentives, COMMUNITY_ALLOCATION, "Community Incentives");

        _mint(teamAndAdvisors, TEAM_ALLOCATION);
        emit TokensDistributed(teamAndAdvisors, TEAM_ALLOCATION, "Team & Advisors");

        _mint(earlyInvestors, INVESTOR_ALLOCATION);
        emit TokensDistributed(earlyInvestors, INVESTOR_ALLOCATION, "Early Investors");

        _mint(daoTreasury, DAO_ALLOCATION);
        emit TokensDistributed(daoTreasury, DAO_ALLOCATION, "DAO Treasury");

        _mint(publicSale, PUBLIC_ALLOCATION);
        emit TokensDistributed(publicSale, PUBLIC_ALLOCATION, "Public Sale");
    }

    /**
     * @dev 多重继承必需的重写
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        super._update(from, to, value);
    }
}
