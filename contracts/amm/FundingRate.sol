// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FundingRate
 * @notice 永续合约资金费率计算和管理
 * @dev 资金费率 = (Mark Price - Index Price) / Index Price
 *
 * 资金支付 = 持仓量 × 资金费率
 * - 正费率: 多头支付给空头 (mark > index)
 * - 负费率: 空头支付给多头 (mark < index)
 *
 * 每 8 小时计算一次，持续支付
 */
contract FundingRate is AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // 资金费率数据
    struct FundingData {
        int256 currentRate;          // 当前费率 (18位精度)
        uint256 lastUpdateTime;      // 上次更新时间
        int256 cumulativeFunding;    // 累积费率
        uint256 fundingInterval;     // 费率周期 (默认 8 小时)
    }

    // 市场 ID => 资金数据
    mapping(bytes32 => FundingData) public fundingData;

    // 市场 ID => 累积费率快照
    mapping(bytes32 => mapping(uint256 => int256)) public fundingHistory;

    // 常量配置
    uint256 public constant FUNDING_INTERVAL = 8 hours;
    uint256 public constant MAX_FUNDING_RATE = 5e16;  // 5% 最大费率
    uint256 public constant PRECISION = 1e18;

    // 事件
    event FundingRateUpdated(
        bytes32 indexed marketId,
        int256 fundingRate,
        int256 cumulativeFunding,
        uint256 timestamp
    );

    // 错误
    error InvalidInterval();
    error ZeroPrice();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice 初始化市场的资金费率
     * @param marketId 市场 ID
     */
    function initializeFunding(bytes32 marketId) external onlyRole(OPERATOR_ROLE) {
        if (fundingData[marketId].fundingInterval != 0) return; // 已初始化

        fundingData[marketId] = FundingData({
            currentRate: 0,
            lastUpdateTime: block.timestamp,
            cumulativeFunding: 0,
            fundingInterval: FUNDING_INTERVAL
        });
    }

    /**
     * @notice 更新资金费率
     * @param marketId 市场 ID
     * @param markPrice vAMM 标记价格
     * @param indexPrice 预言机指数价格
     */
    function updateFundingRate(
        bytes32 marketId,
        uint256 markPrice,
        uint256 indexPrice
    ) external onlyRole(OPERATOR_ROLE) {
        if (markPrice == 0 || indexPrice == 0) revert ZeroPrice();

        FundingData storage data = fundingData[marketId];

        // 未到更新时间则跳过
        if (block.timestamp < data.lastUpdateTime + data.fundingInterval) {
            return;
        }

        // 计算费率: (markPrice - indexPrice) / indexPrice
        int256 fundingRate = _calculateFundingRate(markPrice, indexPrice);

        // 更新累积费率
        int256 timeSinceUpdate = int256(block.timestamp - data.lastUpdateTime);
        int256 fundingIncrement = (fundingRate * timeSinceUpdate) / int256(data.fundingInterval);

        data.currentRate = fundingRate;
        data.cumulativeFunding += fundingIncrement;
        data.lastUpdateTime = block.timestamp;

        // 记录历史
        fundingHistory[marketId][block.timestamp] = data.cumulativeFunding;

        emit FundingRateUpdated(marketId, fundingRate, data.cumulativeFunding, block.timestamp);
    }

    /**
     * @notice 计算持仓的资金支付
     * @param marketId 市场 ID
     * @param positionSize 持仓量 (正=多头, 负=空头)
     * @param entryFunding 开仓时的累积费率
     * @return payment 支付金额 (正=收取, 负=支付)
     */
    function calculateFundingPayment(
        bytes32 marketId,
        int256 positionSize,
        int256 entryFunding
    ) public view returns (int256 payment) {
        if (positionSize == 0) return 0;

        FundingData memory data = fundingData[marketId];

        // 支付 = 持仓量 × (当前累积费率 - 开仓时费率)
        // 多头: 费率为正时支付，为负时收取
        // 空头: 费率为正时收取，为负时支付
        int256 fundingDelta = data.cumulativeFunding - entryFunding;
        payment = (positionSize * fundingDelta) / int256(PRECISION);
    }

    /**
     * @notice 获取当前资金费率
     * @param marketId 市场 ID
     * @return rate 当前费率
     * @return nextUpdate 下次更新时间
     */
    function getCurrentFundingRate(bytes32 marketId)
        external
        view
        returns (int256 rate, uint256 nextUpdate)
    {
        FundingData memory data = fundingData[marketId];
        return (data.currentRate, data.lastUpdateTime + data.fundingInterval);
    }

    /**
     * @notice 获取累积资金费率
     * @param marketId 市场 ID
     */
    function getCumulativeFunding(bytes32 marketId) external view returns (int256) {
        return fundingData[marketId].cumulativeFunding;
    }

    /**
     * @notice 预览资金费率
     * @param markPrice 标记价格
     * @param indexPrice 指数价格
     * @return fundingRate 预计费率
     */
    function calculateFundingRatePreview(
        uint256 markPrice,
        uint256 indexPrice
    ) external pure returns (int256 fundingRate) {
        if (markPrice == 0 || indexPrice == 0) revert ZeroPrice();
        return _calculateFundingRate(markPrice, indexPrice);
    }

    /**
     * @notice 获取距离下次更新的时间
     * @param marketId 市场 ID
     * @return 剩余秒数
     */
    function getTimeUntilFunding(bytes32 marketId) external view returns (uint256) {
        FundingData memory data = fundingData[marketId];
        uint256 nextUpdate = data.lastUpdateTime + data.fundingInterval;

        return block.timestamp >= nextUpdate ? 0 : nextUpdate - block.timestamp;
    }

    /**
     * @notice 查询历史资金费率
     * @param marketId 市场 ID
     * @param timestamp 时间戳
     */
    function getHistoricalFunding(bytes32 marketId, uint256 timestamp)
        external
        view
        returns (int256)
    {
        return fundingHistory[marketId][timestamp];
    }

    /**
     * @notice 设置资金费率周期 (治理)
     * @param marketId 市场 ID
     * @param newInterval 新周期 (秒)
     */
    function setFundingInterval(bytes32 marketId, uint256 newInterval)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newInterval == 0 || newInterval > 24 hours) revert InvalidInterval();
        fundingData[marketId].fundingInterval = newInterval;
    }

    // ============ 内部函数 ============

    /**
     * @dev 计算资金费率并限制在最大值内
     */
    function _calculateFundingRate(uint256 markPrice, uint256 indexPrice)
        private
        pure
        returns (int256 fundingRate)
    {
        int256 priceDiff = int256(markPrice) - int256(indexPrice);
        fundingRate = (priceDiff * int256(PRECISION)) / int256(indexPrice);

        // 限制在 [-MAX, +MAX] 范围
        if (fundingRate > int256(MAX_FUNDING_RATE)) {
            fundingRate = int256(MAX_FUNDING_RATE);
        } else if (fundingRate < -int256(MAX_FUNDING_RATE)) {
            fundingRate = -int256(MAX_FUNDING_RATE);
        }
    }
}
