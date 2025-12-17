// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ChainlinkAdapter
 * @notice Chainlink 价格源适配器
 * @dev 从 Chainlink 预言机获取价格并标准化为 18 位小数
 */
contract ChainlinkAdapter is Ownable {
    // 资产 => Chainlink 价格源
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // 常量配置
    uint256 public constant MAX_PRICE_AGE = 1 hours;  // 最大价格有效期
    uint256 public constant TARGET_DECIMALS = 18;     // 目标精度

    // 事件
    event PriceFeedSet(address indexed asset, address indexed priceFeed);
    event PriceFeedRemoved(address indexed asset);

    // 错误
    error PriceFeedNotSet();
    error StalePrice();
    error InvalidPrice();
    error ZeroAddress();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice 设置资产的 Chainlink 价格源
     * @param asset 资产地址
     * @param priceFeed Chainlink 价格源地址
     */
    function setPriceFeed(address asset, address priceFeed) external onlyOwner {
        if (asset == address(0) || priceFeed == address(0)) revert ZeroAddress();
        priceFeeds[asset] = AggregatorV3Interface(priceFeed);
        emit PriceFeedSet(asset, priceFeed);
    }

    /**
     * @notice 移除资产的价格源
     * @param asset 资产地址
     */
    function removePriceFeed(address asset) external onlyOwner {
        delete priceFeeds[asset];
        emit PriceFeedRemoved(asset);
    }

    /**
     * @notice 获取资产的最新价
     * @param asset 资产地址
     * @return price 标准化后的价格 (18位精度)
     * @return timestamp 价格更新时间
     */
    function getPrice(address asset) external view returns (uint256 price, uint256 timestamp) {
        AggregatorV3Interface priceFeed = priceFeeds[asset];
        if (address(priceFeed) == address(0)) revert PriceFeedNotSet();

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // 价格数据验证
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice();

        // 标准化为 18 位小数
        uint8 feedDecimals = priceFeed.decimals();
        price = _normalizePrice(uint256(answer), feedDecimals);
        timestamp = updatedAt;
    }

    /**
     * @notice 检查资产是否配置了价格源
     * @param asset 资产地址
     */
    function hasPriceFeed(address asset) external view returns (bool) {
        return address(priceFeeds[asset]) != address(0);
    }

    /**
     * @notice 获取资产的价格源地址
     * @param asset 资产地址
     */
    function getPriceFeed(address asset) external view returns (address) {
        return address(priceFeeds[asset]);
    }

    /**
     * @dev 标准化价格精度到 18 位
     */
    function _normalizePrice(uint256 price, uint8 decimals) private pure returns (uint256) {
        if (decimals == TARGET_DECIMALS) {
            return price;
        } else if (decimals < TARGET_DECIMALS) {
            return price * (10 ** (TARGET_DECIMALS - decimals));
        } else {
            return price / (10 ** (decimals - TARGET_DECIMALS));
        }
    }
}
