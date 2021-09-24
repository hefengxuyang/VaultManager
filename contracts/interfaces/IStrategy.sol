// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IStrategy {
    function harvest(address _pair) external;

    function convertReward(address _pair) external;

    function convertRemain(address _pair, address _fromToken) external;

    function rebalance(address _oldPair, address _newPair, uint256 _liquidity) external;
}
