// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IManager {
    function deposit(uint256 _amount0, uint256 _amount1, address _to) external returns (uint256, uint256, uint256);

    function withdraw(uint256 _shares, address _to) external returns (uint256, uint256);

    function getTotalAmounts() external view returns (uint256, uint256);
}
