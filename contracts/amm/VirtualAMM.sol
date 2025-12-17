// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title VirtualAMM
 * @notice 永续合约虚拟自动做市商
 * @dev 使用恒定乘积公式 (x * y = k)，无需真实流动性
 *
 * 核心概念:
 * - Base Asset: 虚拟标的资产 (如 BTC, ETH)
 * - Quote Asset: 虚拟计价资产 (如 USD)
 * - K: 恒定乘积 (baseReserve * quoteReserve = k)
 * - 无真实资产锁定，纯粹用于价格发现
 */
contract VirtualAMM is AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // AMM 储备数据
    struct AMMReserves {
        uint256 baseReserve;        // 虚拟 base 资产储备
        uint256 quoteReserve;       // 虚拟 quote 资产储备
        uint256 k;                  // 恒定乘积 k = x * y
        uint256 totalPositionSize;  // 总持仓量
        uint256 openInterestLong;   // 多头未平仓量
        uint256 openInterestShort;  // 空头未平仓量
    }

    // 市场配置
    struct MarketConfig {
        uint256 maxSlippage;        // 最大滑点 (基点)
        uint256 fundingPeriod;      // 资金费率周期
        uint256 maintenanceMargin;  // 维持保证金率 (基点)
        bool isActive;              // 是否激活
    }

    // 市场 ID => 储备数据
    mapping(bytes32 => AMMReserves) public markets;

    // 市场 ID => 配置
    mapping(bytes32 => MarketConfig) public marketConfigs;

    // 常量
    uint256 public constant PRECISION = 1e18;      // 价格精度
    uint256 public constant BASIS_POINTS = 10000;  // 基点

    // 事件
    event MarketCreated(bytes32 indexed marketId, uint256 baseReserve, uint256 quoteReserve);
    event ReservesUpdated(bytes32 indexed marketId, uint256 baseReserve, uint256 quoteReserve);
    event KAdjusted(bytes32 indexed marketId, uint256 oldK, uint256 newK);

    // 错误
    error MarketNotActive();
    error MarketAlreadyExists();
    error ZeroAmount();
    error SlippageExceeded();
    error InvalidReserves();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /**
     * @notice 创建新市场
     * @param marketId 市场唯一标识符
     * @param baseReserve 初始 base 储备
     * @param quoteReserve 初始 quote 储备
     * @param maxSlippage 最大滑点 (基点)
     */
    function createMarket(
        bytes32 marketId,
        uint256 baseReserve,
        uint256 quoteReserve,
        uint256 maxSlippage
    ) external onlyRole(ADMIN_ROLE) {
        if (markets[marketId].k != 0) revert MarketAlreadyExists();
        if (baseReserve == 0 || quoteReserve == 0) revert InvalidReserves();

        uint256 k = baseReserve * quoteReserve;

        markets[marketId] = AMMReserves({
            baseReserve: baseReserve,
            quoteReserve: quoteReserve,
            k: k,
            totalPositionSize: 0,
            openInterestLong: 0,
            openInterestShort: 0
        });

        marketConfigs[marketId] = MarketConfig({
            maxSlippage: maxSlippage,
            fundingPeriod: 8 hours,
            maintenanceMargin: 500, // 5%
            isActive: true
        });

        emit MarketCreated(marketId, baseReserve, quoteReserve);
    }

    /**
     * @notice 计算兑换输出量
     * @param marketId 市场 ID
     * @param inputAmount 输入数量
     * @param isLong true=做多(买base), false=做空(卖base)
     * @return outputAmount 输出数量
     */
    function getOutputAmount(
        bytes32 marketId,
        uint256 inputAmount,
        bool isLong
    ) public view returns (uint256 outputAmount) {
        if (!marketConfigs[marketId].isActive) revert MarketNotActive();
        if (inputAmount == 0) revert ZeroAmount();

        AMMReserves memory reserves = markets[marketId];

        if (isLong) {
            // 买 base: quoteIn -> baseOut
            // 新 quote 储备 = 当前储备 + 输入
            // 新 base 储备 = k / 新 quote 储备
            // 输出 = 当前 base - 新 base
            uint256 newQuoteReserve = reserves.quoteReserve + inputAmount;
            uint256 newBaseReserve = reserves.k / newQuoteReserve;
            outputAmount = reserves.baseReserve - newBaseReserve;
        } else {
            // 卖 base: baseIn -> quoteOut
            uint256 newBaseReserve = reserves.baseReserve + inputAmount;
            uint256 newQuoteReserve = reserves.k / newBaseReserve;
            outputAmount = reserves.quoteReserve - newQuoteReserve;
        }
    }

    /**
     * @notice 获取现货价格 (quote/base)
     * @param marketId 市场 ID
     * @return price 价格 (18位精度)
     */
    function getSpotPrice(bytes32 marketId) public view returns (uint256 price) {
        AMMReserves memory reserves = markets[marketId];
        if (reserves.baseReserve == 0) revert InvalidReserves();

        // 价格 = quoteReserve / baseReserve
        price = (reserves.quoteReserve * PRECISION) / reserves.baseReserve;
    }

    /**
     * @notice 执行兑换
     * @param marketId 市场 ID
     * @param inputAmount 输入数量
     * @param isLong 做多/做空
     * @param minOutput 最小输出 (滑点保护)
     * @return outputAmount 实际输出
     */
    function swap(
        bytes32 marketId,
        uint256 inputAmount,
        bool isLong,
        uint256 minOutput
    ) external onlyRole(OPERATOR_ROLE) nonReentrant returns (uint256 outputAmount) {
        if (!marketConfigs[marketId].isActive) revert MarketNotActive();
        if (inputAmount == 0) revert ZeroAmount();

        AMMReserves storage reserves = markets[marketId];

        // 计算输出
        outputAmount = getOutputAmount(marketId, inputAmount, isLong);

        // 滑点检查
        if (outputAmount < minOutput) revert SlippageExceeded();

        // 更新储备和持仓
        if (isLong) {
            reserves.quoteReserve += inputAmount;
            reserves.baseReserve -= outputAmount;
            reserves.openInterestLong += outputAmount;
            reserves.totalPositionSize += outputAmount;
        } else {
            reserves.baseReserve += inputAmount;
            reserves.quoteReserve -= outputAmount;
            reserves.openInterestShort += inputAmount;
            reserves.totalPositionSize += inputAmount;
        }

        emit ReservesUpdated(marketId, reserves.baseReserve, reserves.quoteReserve);

        return outputAmount;
    }

    /**
     * @notice 调整 K 值重新平衡 AMM (治理操作)
     * @dev 用于将虚拟价格对齐到预言机价格
     * @param marketId 市场 ID
     * @param targetPrice 目标价格 (来自预言机)
     */
    function adjustK(bytes32 marketId, uint256 targetPrice)
        external
        onlyRole(ADMIN_ROLE)
    {
        AMMReserves storage reserves = markets[marketId];
        uint256 currentPrice = getSpotPrice(marketId);

        if (targetPrice == currentPrice) return;

        uint256 oldK = reserves.k;

        // 保持 baseReserve 不变，调整 quoteReserve
        // targetPrice = quoteReserve / baseReserve
        // newQuoteReserve = targetPrice * baseReserve / PRECISION
        reserves.quoteReserve = (targetPrice * reserves.baseReserve) / PRECISION;
        reserves.k = reserves.baseReserve * reserves.quoteReserve;

        emit KAdjusted(marketId, oldK, reserves.k);
        emit ReservesUpdated(marketId, reserves.baseReserve, reserves.quoteReserve);
    }

    /**
     * @notice 获取市场信息
     * @param marketId 市场 ID
     */
    function getMarketInfo(bytes32 marketId)
        external
        view
        returns (
            uint256 baseReserve,
            uint256 quoteReserve,
            uint256 spotPrice,
            uint256 totalPositionSize
        )
    {
        AMMReserves memory reserves = markets[marketId];
        return (
            reserves.baseReserve,
            reserves.quoteReserve,
            getSpotPrice(marketId),
            reserves.totalPositionSize
        );
    }

    /**
     * @notice 计算价格冲击
     * @param marketId 市场 ID
     * @param inputAmount 交易数量
     * @param isLong 做多/做空
     * @return priceImpact 价格冲击 (基点)
     */
    function calculatePriceImpact(
        bytes32 marketId,
        uint256 inputAmount,
        bool isLong
    ) external view returns (uint256 priceImpact) {
        uint256 priceBefore = getSpotPrice(marketId);
        AMMReserves memory reserves = markets[marketId];

        // 模拟兑换后的储备
        if (isLong) {
            reserves.quoteReserve += inputAmount;
            reserves.baseReserve = reserves.k / reserves.quoteReserve;
        } else {
            reserves.baseReserve += inputAmount;
            reserves.quoteReserve = reserves.k / reserves.baseReserve;
        }

        uint256 priceAfter = (reserves.quoteReserve * PRECISION) / reserves.baseReserve;

        // 计算冲击百分比 (基点)
        uint256 priceDiff = priceAfter > priceBefore
            ? priceAfter - priceBefore
            : priceBefore - priceAfter;

        priceImpact = (priceDiff * BASIS_POINTS) / priceBefore;
    }

    /**
     * @notice 更新市场配置
     * @param marketId 市场 ID
     * @param maxSlippage 最大滑点
     * @param isActive 是否激活
     */
    function updateMarketConfig(
        bytes32 marketId,
        uint256 maxSlippage,
        bool isActive
    ) external onlyRole(ADMIN_ROLE) {
        MarketConfig storage config = marketConfigs[marketId];
        config.maxSlippage = maxSlippage;
        config.isActive = isActive;
    }

    /**
     * @notice 获取未平仓量
     * @param marketId 市场 ID
     * @return longOI 多头
     * @return shortOI 空头
     */
    function getOpenInterest(bytes32 marketId)
        external
        view
        returns (uint256 longOI, uint256 shortOI)
    {
        AMMReserves memory reserves = markets[marketId];
        return (reserves.openInterestLong, reserves.openInterestShort);
    }
}
