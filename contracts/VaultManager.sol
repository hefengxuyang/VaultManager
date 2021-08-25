// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/swap/ISwapV2Factory.sol";
import "./interfaces/swap/ISwapV2Pair.sol";
import "./interfaces/IManager.sol";
import "./VaultController.sol";

/**
 * @title VaultManager
 * @author yang
 * @notice This contract is the primary contract for the minning pool.
 */
contract VaultManager is IManager, Ownable, ERC20, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public fundDisabled; // Boolean that, if true, disables the primary functionality of this contract.

    address payable private vaultControllerContract; // Address of the VaultController.
    VaultController public vaultController;    // VaultController contract object.

    address public immutable basePair;      // Initilize of the pair
    address public immutable token0;         // The first token of the pair
    address public immutable token1;         // The second token of the pair

    uint256 public maxTotalSupply;       // The max total supply for shares.
    uint256 public withdrawalFeeRate;    // The current withdrawal fee rate (scaled by 1e18).
    address public withdrawalFeeBeneficiary;    // The master beneficiary of withdrawal fees; i.e., the recipient of all withdrawal fees.

    event FundDisabled();   // Emitted when the primary functionality of this contract has been disabled.
    event FundEnabled();    // Emitted when the primary functionality of this contract has been enabled.
    event Deposit(address indexed _sender, address indexed _to, uint256 _share, uint256 _amount0, uint256 _amount1);    // Emitted when funds have been deposited to Controller.
    event Withdraw(address indexed _sender, address indexed _to, uint256 _share, uint256 _amount0, uint256 _amount1);  // Emitted when funds have been withdrawn from Controller.

    modifier fundEnabled() {    // Throws if fund is disabled.
        require(!fundDisabled, "This fund manager contract is disabled. This may be due to an upgrade.");
        _;
    }

    // initilize the contract
    constructor (
        address _pair,
        uint256 _withdrawalFeeRate,
        uint256 _maxTotalSupply
    ) public ERC20("Fund Vault", "FV") {  
        basePair = _pair;
        token0 = ISwapV2Pair(_pair).token0();
        token1 = ISwapV2Pair(_pair).token1();

        withdrawalFeeRate = _withdrawalFeeRate;
        maxTotalSupply = _maxTotalSupply;
        withdrawalFeeBeneficiary = msg.sender;
    }

    // set the contract disabled
    function setFundDisabled(bool _fundDisabled) external onlyOwner {
        require(_fundDisabled != fundDisabled, "No change to fund enabled/disabled status.");
        fundDisabled = _fundDisabled;
        if (_fundDisabled) 
            emit FundDisabled(); 
        else 
            emit FundEnabled();
    }

    // set the VaultController address
    function setVaultController(address payable _vaultController) external fundEnabled onlyOwner {
        vaultControllerContract = _vaultController;
        vaultController = VaultController(vaultControllerContract);
    }

    // set the max totalSupply
    function setMaxTotalSupply(uint256 _maxTotalSupply) external fundEnabled onlyOwner {
        maxTotalSupply = _maxTotalSupply;
    }

    // set withdraw fee rate
    function setWithdrawalFeeRate(uint256 _rate) external fundEnabled onlyOwner {
        require(_rate != withdrawalFeeRate, "The same withdrawal fee rate.");
        require(_rate <= 1e18, "Feerate cannot be greater than 100%.");
        withdrawalFeeRate = _rate;
    }

    // set the beneficiary of the withdrawal fee 
    function setWithdrawalFeeBeneficiary(address _beneficiary) external fundEnabled onlyOwner {
        require(_beneficiary != address(0), "Beneficiary cannot be the zero address.");
        withdrawalFeeBeneficiary = _beneficiary;
    }

    // deposit
    function deposit(
        uint256 _amount0Desired,
        uint256 _amount1Desired,
        address _to
    ) external override fundEnabled nonReentrant returns (
        uint256 shares, 
        uint256 amount0, 
        uint256 amount1
    ) {
        require(_amount0Desired > 0 && _amount1Desired > 0, "The amount0Desired or amount1Desired is zero");
        require(_to != address(0), "Invalid receive address");

        // Calculate the optimal amouts proportional by base pair
        require(ISwapV2Factory(ISwapV2Pair(basePair).factory()).getPair(token0, token1) != address(0), "Not exist pair");
        (uint256 reserve0, uint256 reserve1, ) = ISwapV2Pair(basePair).getReserves();
        uint256 amount1Optimal = _amount0Desired.mul(reserve1) / reserve0;
        if (amount1Optimal <= _amount1Desired) {
            (amount0, amount1) = (_amount0Desired, amount1Optimal);
        } else {
            uint256 amount0Optimal = _amount1Desired.mul(reserve0) / reserve1;
            assert(amount0Optimal <= _amount0Desired);
            (amount0, amount1) = (amount0Optimal, _amount1Desired);
        }

        // Calculate shares for amounts proportional to vault's holdings
        shares = _calcShares(amount0, amount1);
        require(shares > 0, "Invalid shares and amounts");

        // Pull in tokens from sender
        IERC20(token0).safeTransferFrom(msg.sender, vaultControllerContract, amount0);
        IERC20(token1).safeTransferFrom(msg.sender, vaultControllerContract, amount1);

        // Compose into the base pair liquity
        vaultController.composeByManager(basePair, amount0, amount1, uint256(-1));

        // Mint shares to recipient
        _mint(_to, shares);
        require(totalSupply() <= maxTotalSupply, "Exceed maxTotalSupply");
        emit Deposit(msg.sender, _to, shares, amount0, amount1);
    }

    // calculate the shares and the needed amount0, amount1
    function _calcShares(uint256 _amount0, uint256 _amount1) internal view returns (uint256 shares) {
        uint256 totalSupply = totalSupply();
        (uint256 total0, uint256 total1) = getTotalAmounts();

        // If total supply > 0, vault can't be empty
        assert(totalSupply == 0 || (total0 > 0 && total1 > 0));

        if (totalSupply == 0) {
            shares = Math.min(_amount0, _amount1);
        } else {
            uint256 cross = Math.min(_amount0.mul(total1), _amount1.mul(total0));
            shares = cross.mul(totalSupply).div(total0).div(total1);
        }
    }

    // calculate the VaultController contract balance of total token0 and token1
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        address[] memory pairs = vaultController.getSupportedPairs();
        for (uint256 i = 0; i < pairs.length; i++) {
            address curPairToken = pairs[i];
            uint256 curReservedAmount = vaultController.getTokenBalance(curPairToken);
            uint256 curStakedAmount = vaultController.getPoolPrincipal(curPairToken);
            uint256 curPairAmount = curReservedAmount.add(curStakedAmount);

            uint256 balance0 = IERC20(token0).balanceOf(curPairToken);
            uint256 balance1 = IERC20(token1).balanceOf(curPairToken);
            uint256 totalSupply = ISwapV2Pair(curPairToken).totalSupply();
            uint256 amount0 = curPairAmount.mul(balance0) / totalSupply;
            uint256 amount1 = curPairAmount.mul(balance1) / totalSupply;
            total0 = total0.add(amount0);
            total1 = total1.add(amount1);
        }
    }

    // withdraw
    function withdraw(
        uint256 _shares,
        address _to
    ) external override fundEnabled nonReentrant returns (
        uint256 amount0, 
        uint256 amount1
    ) {
        require(_shares > 0, "Invalid shares");
        require(_to != address(0), "Invalid receive address");
        uint256 totalSupply = totalSupply();
        require(totalSupply > 0, "Can't withdraw with zero deposit");

        // Burn shares
        _burn(msg.sender, _shares);
        (amount0, amount1) = _withdrawPrincipal(_shares, totalSupply, _to);    // Send principal tokens to recipient
        _withdrawReward(_shares, totalSupply, _to);       // Send reward tokens to recipient
        
        emit Withdraw(msg.sender, _to, _shares, amount0, amount1);
    }

    // withdraw from VaultController by shares
    function _withdrawFromPools(
        uint256 _shares, 
        uint256 _totalSupply
    ) internal returns (
        uint256 totalAmount0, 
        uint256 totalAmount1
    ) {
        address[] memory pairs = vaultController.getSupportedPairs();
        uint256 deadline = uint256(-1);
        for (uint256 i = 0; i < pairs.length; i++) {
            address curPairToken = pairs[i];
            uint256 stakedAmount = vaultController.getPoolPrincipal(curPairToken);
            uint256 withdrawAmount = stakedAmount.mul(_shares).div(_totalSupply);
            vaultController.withdrawFromPoolByManager(curPairToken, withdrawAmount);  // withdraw contain principal and reward 
            (uint256 amount0, uint256 amount1) = vaultController.splitByManager(curPairToken, withdrawAmount, deadline);
            totalAmount0 = totalAmount0.add(amount0);
            totalAmount1 = totalAmount1.add(amount1);
        }
    }

    // withdraw from principal by shares
    function _withdrawPrincipal(
        uint256 _shares, 
        uint256 _totalSupply, 
        address _to
    ) internal returns (
        uint256 amount0, 
        uint256 amount1
    ){
        // Calculate token amounts proportional for reserved balances
        uint256 reservedBalance0 = vaultController.getTokenBalance(token0);
        uint256 reservedBalance1 = vaultController.getTokenBalance(token1);
        uint256 reservedAmount0 = reservedBalance0.mul(_shares).div(_totalSupply);
        uint256 reservedAmount1 = reservedBalance1.mul(_shares).div(_totalSupply);

        // Withdraw proportion of liquidity from mining pool
        (uint256 stakedAmount0, uint256 stakedAmount1) = _withdrawFromPools(_shares, _totalSupply);

        // Sum up total amounts owed to recipient
        amount0 = reservedAmount0.add(stakedAmount0);
        amount1 = reservedAmount1.add(stakedAmount1);

        // Withdraw proportion of principal to recipient
        uint256 feeAmount0 = amount0.mul(withdrawalFeeRate).div(1e18);
        uint256 feeAmount1 = amount1.mul(withdrawalFeeRate).div(1e18);
        uint256 amount0AfterFee = amount0.sub(feeAmount0);
        uint256 amount1AfterFee = amount1.sub(feeAmount1);
        IERC20(token0).safeTransferFrom(vaultControllerContract, withdrawalFeeBeneficiary, feeAmount0);
        IERC20(token1).safeTransferFrom(vaultControllerContract, withdrawalFeeBeneficiary, feeAmount1);
        IERC20(token0).safeTransferFrom(vaultControllerContract, _to, amount0AfterFee);
        IERC20(token1).safeTransferFrom(vaultControllerContract, _to, amount1AfterFee);
    }

    // withdraw from reward by shares
    function _withdrawReward(
        uint256 _shares, 
        uint256 _totalSupply, 
        address _to
    ) internal {
        address[] memory pairs = vaultController.getSupportedPairs();
        for (uint256 i = 0; i < pairs.length; i++) {
            address rewardToken = vaultController.getRewardToken(pairs[i]);
            uint256 totalRewardAmount = vaultController.getTokenBalance(rewardToken);
            uint256 rewardAmount = totalRewardAmount.mul(_shares).div(_totalSupply);
            uint256 rewardFeeAmount = rewardAmount.mul(withdrawalFeeRate).div(1e18);
            uint256 rewardAmountAfterFee = rewardAmount.sub(rewardFeeAmount);
            IERC20(rewardToken).safeTransferFrom(vaultControllerContract, withdrawalFeeBeneficiary, rewardFeeAmount);
            IERC20(rewardToken).safeTransferFrom(vaultControllerContract, _to, rewardAmountAfterFee);
        }
    }

    // forward the lost funds to user
    function forwardLostFunds(address _token, address _to) external onlyOwner returns (bool) {
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        if (balance <= 0) return false;
        token.safeTransfer(_to, balance);
        return true;
    }
}
