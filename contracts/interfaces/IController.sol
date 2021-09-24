// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IController {
    function basePair() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function approveTo(address _token, address _receiver, uint256 _amount) external;

    function approveToMaster(address _pair, uint256 _amount) external;

    function approveToManager(address _token, uint256 _amount) external;

    function depositToPool(address _pair, uint256 _amount) external;

    function withdrawFromPool(address _pair, uint256 _amount) external;

    function split(address _pair, uint256 _liquidity, uint256 _deadline) external returns (uint256, uint256);

    function compose(address _pair, uint256 _desiredAmount0, uint256 _desiredAmount1, uint256 _deadline) external returns (uint256, uint256, uint256);

    function migrate(address _oldPair, address _newPair, uint256 _liquidity, uint256 _deadline) external returns (uint256);

    function swap(address _pair, uint256 _amount, address[] calldata path, uint256 _deadline) external returns (uint256[] memory);

    function swapReward(address _pair, uint256 _amount, address _toToken, uint256 _deadline) external returns (uint256[] memory);

    function swapRemain(address _pair, uint256 _amount, address _fromToken, uint256 _deadline) external returns (uint256[] memory);

    function getTokenBalance(address _token) external view returns (uint256);

    function getRewardToken(address _pair) external view returns (address);

    function getPoolReward(address _pair) external view returns (uint256);

    function getPoolPrincipal(address _pair) external view returns (uint256);

    function getSupportedPairs() external view returns (address[] memory);
}
