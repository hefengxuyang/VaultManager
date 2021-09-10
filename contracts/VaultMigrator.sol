// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/swap/ISwapV2Factory.sol';
import './interfaces/swap/ISwapV2Router.sol';

/**
 * @title VaultMigrator
 * @notice VaultMigrator migrate liquity.
 */
contract VaultMigrator {
    using SafeMath for uint256;

    function migrate(
        address _oldRouter, 
        address _newRouter, 
        address _tokenA, 
        address _tokenB, 
        uint256 _oldLiquidity,
        uint256 _deadline) external returns (uint256) {
        require(_oldRouter != address(0) && _newRouter != address(0), "ZERO_ADDRESS_FOR_ROUTER");

        uint256 oldAmountA;
        uint256 oldAmountB;
        {
            // scope for removeLiquidity, avoids stack too deep errors
            address factory = ISwapV2Router(_oldRouter).factory();
            address pair = ISwapV2Factory(factory).getPair(_tokenA, _tokenB);
            TransferHelper.safeApprove(pair, _oldRouter, _oldLiquidity);
            (oldAmountA, oldAmountB) = ISwapV2Router(_oldRouter).removeLiquidity(_tokenA, _tokenB, _oldLiquidity, 1, 1, msg.sender, _deadline);
        }
        
        uint256 newAmountA;
        uint256 newAmountB;
        uint256 newLiquidity;
        {
            // scope for addLiquidity, avoids stack too deep errors
            TransferHelper.safeApprove(_tokenA, _newRouter, oldAmountA);
            TransferHelper.safeApprove(_tokenB, _newRouter, oldAmountB);
            (newAmountA, newAmountB, newLiquidity) = ISwapV2Router(_newRouter).addLiquidity(_tokenA, _tokenB, oldAmountA, oldAmountB, 1, 1, msg.sender, _deadline);
        }

        // transfer left token
        if (oldAmountA > newAmountA) {
            TransferHelper.safeApprove(_tokenA, _newRouter, 0); // be a good blockchain citizen, reset allowance to 0
            TransferHelper.safeTransfer(_tokenA, msg.sender, oldAmountA - newAmountA);
        } else if (oldAmountB > newAmountB) {
            TransferHelper.safeApprove(_tokenB, _newRouter, 0);
            TransferHelper.safeTransfer(_tokenB, msg.sender, oldAmountB - newAmountB);
        }
        return newLiquidity;
    }
}
