// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @notice 多源价格预言机，使用中位数防止操纵
 * @dev 从多个来源聚合价格（Chainlink, Pyth等）
 *
 * 安全特性:
 * - 多源价格聚合
 * - 中位数算法防操纵
 * - ±3σ 偏差监控
 * - 价格时效性检查防 MEV 攻击
 */
contract PriceOracle is IPriceOracle, Ownable, ReentrancyGuard {
    // 价格数据结构
    struct PriceData {
        uint256 price;        // 最新聚合价格
        uint256 timestamp;    // 更新时间戳
        uint256 deviation;    // 标准差
        bool isValid;         // 价格是否有效
    }

    // 价格源配置
    struct PriceSource {
        address adapter;      // 价格适配器地址
        uint256 weight;       // 权重 (1-100, 暂未使用)
        bool isActive;        // 是否激活
    }

    // 资产 => 价格数据
    mapping(address => PriceData) public prices;

    // 资产 => 价格源数组
    mapping(address => PriceSource[]) public priceSources;

    // 常量配置
    uint256 public constant MAX_PRICE_AGE = 5 minutes;  // 最大价格有效期
    uint256 public constant MAX_DEVIATION = 3;          // 最大偏差 3%
    uint256 public constant MIN_SOURCES = 1;            // 最少价格源数量

    // 事件 (继承自 IPriceOracle)
    event PriceDeviationAlert(address indexed asset, uint256 deviation);

    // 错误
    error NoPriceSources();
    error InvalidPriceSource();
    error StalePrice();
    error ZeroAddress();
    error InvalidWeight();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice 添加价格源
     * @param asset 资产地址
     * @param adapter 适配器地址
     * @param weight 权重 (1-100)
     */
    function addPriceSource(
        address asset,
        address adapter,
        uint256 weight
    ) external onlyOwner {
        if (asset == address(0) || adapter == address(0)) revert ZeroAddress();
        if (weight == 0 || weight > 100) revert InvalidWeight();

        priceSources[asset].push(PriceSource({
            adapter: adapter,
            weight: weight,
            isActive: true
        }));

        emit PriceSourceAdded(asset, adapter);
    }

    /**
     * @notice 移除价格源
     * @param asset 资产地址
     * @param index 源索引
     */
    function removePriceSource(address asset, uint256 index) external onlyOwner {
        require(index < priceSources[asset].length, "Invalid index");

        address adapter = priceSources[asset][index].adapter;

        // 交换到最后并删除，节省 gas
        priceSources[asset][index] = priceSources[asset][priceSources[asset].length - 1];
        priceSources[asset].pop();

        emit PriceSourceRemoved(asset, adapter);
    }

    /**
     * @notice 更新资产价格
     * @param asset 资产地址
     */
    function updatePrice(address asset) external nonReentrant {
        PriceSource[] memory sources = priceSources[asset]; // gas优化: 一次性读取
        if (sources.length < MIN_SOURCES) revert NoPriceSources();

        // 收集有效价格
        uint256[] memory validPrices = new uint256[](sources.length);
        uint256 validCount = _collectPrices(asset, sources, validPrices);

        if (validCount == 0) revert NoPriceSources();

        // 计算中位数和偏差
        uint256 medianPrice = _calculateMedian(validPrices, validCount);
        uint256 deviation = _calculateDeviation(validPrices, validCount, medianPrice);

        // 偏差警告
        if (deviation > MAX_DEVIATION) {
            emit PriceDeviationAlert(asset, deviation);
        }

        // 更新价格数据
        prices[asset] = PriceData({
            price: medianPrice,
            timestamp: block.timestamp,
            deviation: deviation,
            isValid: deviation <= MAX_DEVIATION
        });

        emit PriceUpdated(asset, medianPrice, block.timestamp);
    }

    /**
     * @notice 获取最新价格
     * @param asset 资产地址
     * @return price 价格 (18位精度)
     * @return timestamp 更新时间
     */
    function getPrice(address asset) external view override returns (uint256 price, uint256 timestamp) {
        PriceData memory data = prices[asset];
        if (data.timestamp == 0) revert StalePrice();
        if (block.timestamp - data.timestamp > MAX_PRICE_AGE) revert StalePrice();

        return (data.price, data.timestamp);
    }

    /**
     * @notice 获取所有源的价格
     * @param asset 资产地址
     */
    function getPrices(address asset) external view override returns (uint256[] memory) {
        uint256 sourceCount = priceSources[asset].length;
        uint256[] memory allPrices = new uint256[](sourceCount);

        for (uint256 i = 0; i < sourceCount; i++) {
            try this.getPriceFromAdapter(priceSources[asset][i].adapter, asset) returns (
                uint256 price,
                uint256
            ) {
                allPrices[i] = price;
            } catch {
                allPrices[i] = 0;
            }
        }

        return allPrices;
    }

    /**
     * @notice 检查价格是否有效
     * @param asset 资产地址
     */
    function isPriceValid(address asset) external view override returns (bool) {
        PriceData memory data = prices[asset];
        return data.isValid && (block.timestamp - data.timestamp <= MAX_PRICE_AGE);
    }

    /**
     * @notice 从适配器获取价格 (供 try-catch 使用)
     * @param adapter 适配器地址
     * @param asset 资产地址
     */
    function getPriceFromAdapter(address adapter, address asset)
        external
        view
        returns (uint256 price, uint256 timestamp)
    {
        (bool success, bytes memory data) = adapter.staticcall(
            abi.encodeWithSignature("getPrice(address)", asset)
        );

        if (!success) revert InvalidPriceSource();

        (price, timestamp) = abi.decode(data, (uint256, uint256));
    }

    /**
     * @notice 获取资产的价格源数量
     */
    function getSourceCount(address asset) external view returns (uint256) {
        return priceSources[asset].length;
    }

    // ============ 内部函数 ============

    /**
     * @dev 收集所有激活源的有效价格
     */
    function _collectPrices(
        address asset,
        PriceSource[] memory sources,
        uint256[] memory validPrices
    ) private view returns (uint256 validCount) {
        validCount = 0;

        for (uint256 i = 0; i < sources.length; i++) {
            if (!sources[i].isActive) continue;

            try this.getPriceFromAdapter(sources[i].adapter, asset) returns (
                uint256 price,
                uint256 timestamp
            ) {
                // 检查价格新鲜度
                if (block.timestamp - timestamp <= MAX_PRICE_AGE && price > 0) {
                    validPrices[validCount] = price;
                    validCount++;
                }
            } catch {
                continue; // 跳过失败的源
            }
        }
    }

    /**
     * @dev 计算中位数 (简化版冒泡排序)
     */
    function _calculateMedian(uint256[] memory priceList, uint256 count)
        private
        pure
        returns (uint256)
    {
        if (count == 0) return 0;
        if (count == 1) return priceList[0];

        // 冒泡排序 (数据量小，简单高效)
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (priceList[j] > priceList[j + 1]) {
                    (priceList[j], priceList[j + 1]) = (priceList[j + 1], priceList[j]);
                }
            }
        }

        // 返回中位数
        return count % 2 == 0
            ? (priceList[count / 2 - 1] + priceList[count / 2]) / 2
            : priceList[count / 2];
    }

    /**
     * @dev 计算标准差百分比
     */
    function _calculateDeviation(
        uint256[] memory priceList,
        uint256 count,
        uint256 median
    ) private pure returns (uint256) {
        if (count <= 1 || median == 0) return 0;

        uint256 sumSquaredDiff = 0;

        // 计算方差
        for (uint256 i = 0; i < count; i++) {
            uint256 diff = priceList[i] > median
                ? priceList[i] - median
                : median - priceList[i];
            sumSquaredDiff += (diff * diff);
        }

        uint256 variance = sumSquaredDiff / count;
        uint256 stdDev = _sqrt(variance);

        // 返回标准差占中位数的百分比
        return (stdDev * 100) / median;
    }

    /**
     * @dev 平方根计算 (Babylonian 方法)
     */
    function _sqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return y;
    }
}
