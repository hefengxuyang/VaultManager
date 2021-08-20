// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./FundController.sol";
import "./FundToken.sol";

/**
 * @title FundManager
 * @notice This contract is the primary contract for the minning pool.
 */
contract FundManager is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;

    bool public fundDisabled; // Boolean that, if true, disables the primary functionality of this FundManager.

    address private fundTokenContract; // 统计提供流动性的量的 erc20 合约, Address of the FundToken.
    FundToken public fundToken; // FundToken 合约对象

    address payable private fundControllerContract; // 流动性池的总操控合约, Address of the FundController.
    FundController public fundController;    // FundController 合约对象

    // 代理合约和旧管理合约，主要用于合约升级
    address private authorizedFundManager;   // Old FundManager contract authorized to migrate its data to the new one.

    address[] public supportedPairTokenContracts;     // Array of the supported liquity pair token contracts
    mapping(address => bool) public pairTokenExists;    // map of exist by mined liquity pair token contract 
    mapping(address => address) public rewardTokenContracts;   // map of reward token by mined liquity pair token contract
    
    // 提现手续费设置（暂不考虑手续费存储手续费）
    uint256 public withdrawalFeeRate;    // The current withdrawal fee rate (scaled by 1e18).
    address public withdrawalFeeMasterBeneficiary;    // The master beneficiary of withdrawal fees; i.e., the recipient of all withdrawal fees.

    // 事件 event 
    event FundManagerUpgraded(address _newFundManager); // Emitted when FundManager is upgraded.
    event FundControllerSet(address _fundController);   // Emitted when the FundController of the FundManager is set or upgraded.
    event FundTokenSet(address _fundToken);    // Emitted when the FundToken of the FundManager is set.
    event FundDisabled();   // Emitted when the primary functionality of this FundManager contract has been disabled.
    event FundEnabled();    // Emitted when the primary functionality of this FundManager contract has been enabled.
    event Deposit(address indexed _pair, address indexed _sender, address indexed _to, uint256 _amount);    // Emitted when funds have been deposited to Controller.
    event Withdrawal(address indexed _pair, address indexed _sender, address indexed _from, uint256 _pairAmount, uint256 _rewardAmount);  // Emitted when funds have been withdrawn from Controller.

    modifier fundEnabled() {    // Throws if fund is disabled.
        require(!fundDisabled, "This fund manager contract is disabled. This may be due to an upgrade.");
        _;
    }

    // 合约初始化
    constructor() public {        
        // 流动性代币入池初始化
        addSupportedPairToken(0x7BDa39b1B4cD4010836E7FC48cb6B817EEcFa94E, 0x30B1832c9D519225020debB21a74621b944A2ca7);
        addSupportedPairToken(0x1F53f4972AAc7985A784C84f739Be4d73FB6d14f, 0x93cAcdd271DA721640D44bd682cFe74ACD34000d);
    }

    function addSupportedPairToken(address _pair, address _rewardToken) internal {
        require(!pairTokenExists[_pair], "Liquity pair token has exists.");
        supportedPairTokenContracts.push(_pair);
        pairTokenExists[_pair] = true;
        rewardTokenContracts[_pair] = _rewardToken;
    }

    /* ============ 升级 FundManager 合约配置 ============ */
    // 设置认证过的旧版本 FundManager 合约
    function setAuthorizeFundManager(address _newAuthorizedFundManager) external onlyOwner {
        require(_newAuthorizedFundManager != address(0), "new authorizeFundManager cannot be the zero address.");
        authorizedFundManager = _newAuthorizedFundManager;
    }

    // 升级新版本的 FundManager 合约
    function upgradeFundManager(address _newFundManager) external onlyOwner {
        require(fundDisabled, "This fund manager contract must be disabled before it can be upgraded.");
        require(_newFundManager != address(0), "new FundManager cannot be the zero address.");
        require(authorizedFundManager != address(0) && msg.sender == authorizedFundManager, "Caller is not an authorized source.");
        
        FundManager(_newFundManager).setWithdrawalFeeRate(FundManager(authorizedFundManager).withdrawalFeeRate());
        FundManager(_newFundManager).setWithdrawalFeeMasterBeneficiary(FundManager(authorizedFundManager).withdrawalFeeMasterBeneficiary());
        emit FundManagerUpgraded(_newFundManager);
    }

    // 设置本合约是否可用
    function setFundDisabled(bool _fundDisabled) external onlyOwner {
        require(_fundDisabled != fundDisabled, "No change to fund enabled/disabled status.");
        fundDisabled = _fundDisabled;
        if (_fundDisabled) 
            emit FundDisabled(); 
        else 
            emit FundEnabled();
    }

    /* ============ 关联合约配置 ============ */
    // 设置资金控制器合约地址 Controller （可接收主网币）
    function setFundController(address payable _fundController) external onlyOwner {
        fundControllerContract = _fundController;
        fundController = FundController(fundControllerContract);
        emit FundControllerSet(_fundController);
    }

    // 设置流动性代币份额合约地址 FundToken，并设置其合约对象
    function setFundToken(address _fundToken) external onlyOwner {
        fundTokenContract = _fundToken;
        fundToken = FundToken(fundTokenContract);
        emit FundTokenSet(_fundToken);
    }

    /* ============ 提现手续费配置 ============ */
    // 设置提现手续费费率
    function setWithdrawalFeeRate(uint256 _rate) external fundEnabled onlyOwner {
        require(_rate != withdrawalFeeRate, "This is already the current withdrawal fee rate.");
        require(_rate <= 1e18, "The withdrawal fee rate cannot be greater than 100%.");
        withdrawalFeeRate = _rate;
    }

    // 设置提现手续费的受益人
    function setWithdrawalFeeMasterBeneficiary(address _beneficiary) external fundEnabled onlyOwner {
        require(_beneficiary != address(0), "Master beneficiary cannot be the zero address.");
        withdrawalFeeMasterBeneficiary = _beneficiary;
    }

    /* ============ 存储和提现的关键部分 ============ */
    // 存入流动性代币
    function depositTo(address _to, address _pair, uint256 _amount) public fundEnabled {
        require(pairTokenExists[_pair], "Invalid liquity pair token.");
        require(_amount > 0, "Deposit amount must be greater than 0.");

        // Update net deposits, transfer funds from msg.sender, mint BLPT, and emit event
        IERC20(_pair).safeTransferFrom(msg.sender, fundControllerContract, _amount); // The user must approve the transfer of tokens beforehand
        fundController.depositToPoolByManager(_pair, _amount);
        require(fundToken.mint(_to, _amount), "Failed to mint fund tokens.");
        emit Deposit(_pair, msg.sender, _to, _amount);
    }

    // 调用者存入流动性代币（调用者用户需要提前 approve 对应的 amount）
    function deposit(address _pair, uint256 _amount) external {
        depositTo(msg.sender, _pair, _amount);
    }

    // 根据资金控制器合约 Controller 中的资金调用情况进行提现
    function withdrawFromPoolsIfNecessary(address _pair, uint256 _amount) internal {
        // Check contract balance of token and withdraw from pools if necessary
        uint256 contractBalance = IERC20(_pair).balanceOf(fundControllerContract);
        if (contractBalance >= _amount) {
            fundController.withdrawFromPoolByManager(_pair, 0); // Only withdraw reward token
            return; 
        }

        uint256 poolPrincipal = fundController.getPoolPrincipal(_pair);
        uint256 amountLeft = _amount.sub(contractBalance);
        bool withdrawAll = amountLeft >= poolPrincipal;
        uint256 poolAmount = withdrawAll ? poolPrincipal : amountLeft;
        fundController.withdrawFromPoolByManager(_pair, poolAmount);
    }

    // 按照流动性代币类别进行对应的提现操作
    // - _from 调用者用户
    // - _pair 挖矿的流动性代币合约
    // - _pairAmount 流动性代币份额合约 fundToken 的数量
    // - _rewardAmount 奖励代币数量
    function _withdrawFrom(address _from, address _pair, uint256 _pairAmount, uint256 _rewardAmount) internal fundEnabled returns (uint256) {
        require(pairTokenExists[_pair], "Invalid liquity pair token.");
        require(_pairAmount != 0 || _rewardAmount != 0, "Both withdrawal principal and reward amount is zero.");

        // withdraw from pools if necessary
        withdrawFromPoolsIfNecessary(_pair, _pairAmount);

        // withdraw reward token
        if (_rewardAmount > 0) {
            IERC20 rewardToken = IERC20(rewardTokenContracts[_pair]);
            rewardToken.safeTransferFrom(fundControllerContract, msg.sender, _rewardAmount);
        } 

        // only withdraw reward token when the amount of pair is zero
        if (_pairAmount == 0) return uint256(0);

        // calculate withdrawal fee and amount after fee
        uint256 feeAmount = _pairAmount.mul(withdrawalFeeRate).div(1e18);
        uint256 amountAfterFee = _pairAmount.sub(feeAmount);

        // withdraw pair token
        fundToken.burnFrom(_from, _pairAmount); // The user must approve the burning of tokens beforehand
        IERC20 pairToken = IERC20(_pair);
        pairToken.safeTransferFrom(fundControllerContract, msg.sender, amountAfterFee);
        pairToken.safeTransferFrom(fundControllerContract, withdrawalFeeMasterBeneficiary, feeAmount);
        return amountAfterFee;
    }

    // 根据资金控制器合约 Controller 中的持仓比例进行等比例的本金和收益提现
    function _withdrawFromPoolByProportion(address _from, uint256 _amount) internal fundEnabled returns (uint256[] memory) {
        uint256 fromBalance = fundToken.balanceOf(_from);
        require(_amount <= fromBalance, "Your BLPT balance is less than the withdrawal amount.");
        bool onlyWithdrawReward = (_amount == 0);
        uint256 calculateWithdrawAmount = onlyWithdrawReward ? fromBalance : _amount;

        // Proportion calculation supportedPairTokenContracts
        uint256[] memory poolPairAmounts = new uint256[](supportedPairTokenContracts.length);
        uint256[] memory poolRewardAmounts = new uint256[](supportedPairTokenContracts.length);
        uint256 totalPoolPairAmount = 0;
        for (uint256 i = 0; i < supportedPairTokenContracts.length; i++) {
            address curPairToken = supportedPairTokenContracts[i];
            address curRewardToken = rewardTokenContracts[curPairToken];
            
            // reward token amount
            uint256 curRewardAmount = fundController.getPoolReward(curPairToken);
            curRewardAmount = curRewardAmount.add(IERC20(curRewardToken).balanceOf(fundControllerContract));
            poolRewardAmounts[i] = curRewardAmount;

            // liquity pair token amount
            uint256 curPairAmount = fundController.getPoolPrincipal(curPairToken);
            curPairAmount = curPairAmount.add(IERC20(curPairToken).balanceOf(fundControllerContract));
            poolPairAmounts[i] = curPairAmount;
            totalPoolPairAmount = totalPoolPairAmount.add(curPairAmount);
        }

        // validate if the total amount is zero
        require(totalPoolPairAmount > 0, "Total LP amount is empty.");

        // withdraw liquity pair token and reward token
        bool enableWithdrawFlag = false;
        uint256[] memory amountsAfterFees = new uint256[](supportedPairTokenContracts.length);
        for (uint256 i = 0; i < supportedPairTokenContracts.length; i++) {
            if (poolPairAmounts[i] == 0) continue;
            uint256 curWithdrawPairAmount = calculateWithdrawAmount.mul(poolPairAmounts[i]).div(totalPoolPairAmount);
            uint256 curWithdrawRewardAmount = poolRewardAmounts[i].mul(curWithdrawPairAmount).div(poolPairAmounts[i]);
            uint256 actualWithdrawPairAmount = onlyWithdrawReward ? 0 : curWithdrawPairAmount;
            if (actualWithdrawPairAmount == 0 && curWithdrawRewardAmount == 0) continue;
            amountsAfterFees[i] = _withdrawFrom(_from, supportedPairTokenContracts[i], actualWithdrawPairAmount, curWithdrawRewardAmount);
            enableWithdrawFlag = true;
            emit Withdrawal(supportedPairTokenContracts[i], msg.sender, _from, actualWithdrawPairAmount, curWithdrawRewardAmount);
        }

        // validate if the total amount is zero
        require(enableWithdrawFlag, "Unable withdraw from pool, because the share amount is too small.");

        // Return amounts after fees
        return amountsAfterFees;
    }

    // 调用者根据自己拥有的流动性代币份额（fundToken）进行提现操作
    function withdraw(uint256 _amount) external returns (uint256[] memory) {
        return _withdrawFromPoolByProportion(msg.sender, _amount);
    }

    // 转出误存的ERC20代币，以防意外操作将资金转移到本合约
    function forwardLostFunds(address _token, address _to) external onlyOwner returns (bool) {
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        if (balance <= 0) return false;
        token.safeTransfer(_to, balance);
        return true;
    }
}
