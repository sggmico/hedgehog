// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @notice Interface for price oracle contracts
 */
interface IPriceOracle {
    /**
     * @notice Get the latest price for an asset
     * @param asset Address of the asset
     * @return price Latest price in USD (scaled by 1e18)
     * @return timestamp When the price was last updated
     */
    function getPrice(address asset) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get prices from multiple sources
     * @param asset Address of the asset
     * @return prices Array of prices from different sources
     */
    function getPrices(address asset) external view returns (uint256[] memory prices);

    /**
     * @notice Check if price data is fresh
     * @param asset Address of the asset
     * @return True if price is within acceptable staleness threshold
     */
    function isPriceValid(address asset) external view returns (bool);

    /**
     * @notice Emitted when price is updated
     * @param asset Asset address
     * @param price New price
     * @param timestamp Update timestamp
     */
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp);

    /**
     * @notice Emitted when price source is added
     * @param asset Asset address
     * @param source Price source address
     */
    event PriceSourceAdded(address indexed asset, address indexed source);

    /**
     * @notice Emitted when price source is removed
     * @param asset Asset address
     * @param source Price source address
     */
    event PriceSourceRemoved(address indexed asset, address indexed source);
}
