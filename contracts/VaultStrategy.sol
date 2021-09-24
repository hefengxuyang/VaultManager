// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/IController.sol";

/**
 * @title VaultStrategy
 * @author yang
 * @notice This contract is used to execute the scheduling strategy by governance.
 */
contract VaultStrategy {
    using SafeMath for uint256;

    address public governance;
    IController public controller;

    event GovernanceSet(address _governance);
    event ControllerSet(address _manager);
    event Harvest(address _rewardToken, uint256 _rewardAmount, address _pair, uint256 _liquidity);
    event Convert(address _fromToken, uint256 _amount, address _pair, uint256 _liquidity);
    event Rebalance(address _oldPair, address _newPair, uint256 _oldLiquidity, uint256 _newLiquidity);

    constructor(
        address _controller
    ) public {
        governance = msg.sender;
        controller = IController(_controller);
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "Caller is not the governance.");
        _;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
        emit GovernanceSet(_governance);
    }

    function setController(address _controller) external onlyGovernance {
        controller = IController(_controller);
        emit ControllerSet(_controller);
    }

    function harvest(address _pair) external onlyGovernance {
        // mark the balance of reward token before harvest
        address rewardToken = controller.getRewardToken(_pair);
        uint256 beforeReward = controller.getTokenBalance(rewardToken);

        // harvest reward token
        controller.withdrawFromPool(_pair, 0);

        // count the balance of reward token after harvest
        uint256 afterReward = controller.getTokenBalance(rewardToken);
        uint256 harvestReward = afterReward.sub(beforeReward);
        uint256 halfHarvestReward = harvestReward.div(2);
        uint256 reserveHarvestReward = harvestReward.sub(halfHarvestReward);
        require(halfHarvestReward > 0, "Zero of half harvest amount.");

        // convert reward token to the pair tokens
        uint256[] memory token0Amounts = controller.swapReward(_pair, halfHarvestReward, controller.token0(), block.timestamp);
        uint256[] memory token1Amounts = controller.swapReward(_pair, reserveHarvestReward, controller.token1(), block.timestamp);

        // add liquidity
        require(token0Amounts.length >= 2 && token1Amounts.length >= 2, "Invalid swap Amounts.");
        (, , uint256 liquidity) = controller.compose(_pair, token0Amounts[1], token1Amounts[1], block.timestamp);

        // deposit to pool
        controller.depositToPool(_pair, liquidity);
        emit Harvest(rewardToken, harvestReward, _pair, liquidity);
    }

    function convertReward(address _pair) external onlyGovernance {
        // query the balance of reward token
        address rewardToken = controller.getRewardToken(_pair);
        uint256 rewardAmount = controller.getTokenBalance(rewardToken);
        uint256 halfRewardAmount = rewardAmount.div(2);
        uint256 reserveRewardAmount = rewardAmount.sub(halfRewardAmount);
        require(halfRewardAmount > 0, "Zero of half reward amount.");

        // convert reward token to the pair tokens
        uint256[] memory token0Amounts = controller.swapReward(_pair, halfRewardAmount, controller.token0(), block.timestamp);
        uint256[] memory token1Amounts = controller.swapReward(_pair, reserveRewardAmount, controller.token1(), block.timestamp);

        // add liquidity
        require(token0Amounts.length >= 2 && token1Amounts.length >= 2, "Invalid swap Amounts.");
        (, , uint256 liquidity) = controller.compose(_pair, token0Amounts[1], token1Amounts[1], block.timestamp);

        // deposit to pool
        controller.depositToPool(_pair, liquidity);
        emit Convert(rewardToken, rewardAmount, _pair, liquidity);
    }

    function convertRemain(address _pair, address _fromToken) external onlyGovernance {        
        // query the balance of from token
        uint256 amount = controller.getTokenBalance(_fromToken);
        uint256 halfAmount = amount.div(2);
        uint256 reserveAmount = amount.sub(halfAmount);
        require(halfAmount > 0, "Zero of half amount.");

        // convert from token to another token, they are the part of pair
        uint256[] memory amounts = controller.swapRemain(_pair, halfAmount, _fromToken, block.timestamp);

        // add liquidity
        require(amounts.length >= 2, "Invalid swap Amounts.");
        (uint256 amount0, uint256 amount1) = _fromToken == controller.token0() ? (reserveAmount, amounts[1]) : (amounts[1], reserveAmount);
        (, , uint256 liquidity) = controller.compose(_pair, amount0, amount1, block.timestamp);

        // deposit to pool
        controller.depositToPool(_pair, liquidity);
        emit Convert(_fromToken, amount, _pair, liquidity);
    }

    function rebalance(
        address _oldPair, 
        address _newPair, 
        uint256 _liquidity
    ) external onlyGovernance {
        // withdraw the liquidity of old pair from pool
        controller.withdrawFromPool(_oldPair, _liquidity);

        // migrate the liquidity from old pair to new pair
        uint256 newLiquidity = controller.migrate(_oldPair, _newPair, _liquidity, block.timestamp);

        // deposit the liquidity of new pair to pool
        controller.depositToPool(_newPair, newLiquidity);
        emit Rebalance(_oldPair, _newPair, _liquidity, newLiquidity);
    }
}