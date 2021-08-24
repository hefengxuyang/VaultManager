// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IMigrator.sol";
import "./interfaces/swap/ISwapV2Pair.sol";
import "./interfaces/swap/ISwapV2Router.sol";
import "./interfaces/master/IBakeryMaster.sol";
import "./interfaces/master/IMdexMaster.sol";
import "./interfaces/master/IPancakeMaster.sol";

/**
 * @title Fund Controller
 * @author yang
 * @notice This contract handles deposits to and withdrawals from the liquidity pools.
 */
contract FundController is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public governance;
    address public rebalancer;
    address public migrator;
    address public fundManager;

    address[] public supportedPairs;

    enum LiquidityPool { BakeryPool, MdexPool, PancakePool }
    mapping(address => LiquidityPool) public masterPools;
    mapping(address => address) public pairMasters;
    mapping(address => address) public pairRouters;
    mapping(address => uint256) public pairPids;
    mapping(address => bool) public pairTokenExists;

    address constant private BAKERY_MASTER_CONTRACT = 0xe17cF95Bd55F749ed56c76193AaafF99422b7487;
    // address constant private MDEX_MASTER_CONTRACT = 0xe2f2a5C287993345a840Db3B0845fbC70f5935a5;
    address constant private PANCAKE_MASTER_CONTRACT = 0x55fC7a3117107adcAE6C6a5b06E69b99C3fa4113;

    event FundGovernanceSet(address _governance);
    event FundRebalancerSet(address _rebalancer);
    event FundMigratorSet(address _migrator);
    event FundManagerSet(address _fundManager);

    event ApproveTo(address _token, address _receiver, uint256 _amount);
    event DepositToPool(address _pair, uint256 _amount);
    event WithdrawFromPool(address _pair, uint256 _amount);
    event Rebalance(uint256 _oldLiquity, uint256 _newLiquity);

    constructor() public {
        governance = msg.sender;
        rebalancer = msg.sender;

        addSupportedMaster(BAKERY_MASTER_CONTRACT, LiquidityPool.BakeryPool);
        // addSupportedMaster(MDEX_MASTER_CONTRACT, LiquidityPool.MdexPool);
        addSupportedMaster(PANCAKE_MASTER_CONTRACT, LiquidityPool.PancakePool);

        addSupportedPair(0x7BDa39b1B4cD4010836E7FC48cb6B817EEcFa94E, BAKERY_MASTER_CONTRACT, 0xf716059b58E95De36635500c2c23761A89A95497, 0);
        // addSupportedPair(0x6B175474E89094C44Da98b954EedeAC495271d0F, MDEX_MASTER_CONTRACT, 0x96C5D20b2a975c050e4220BE276ACe4892f4b41A, 1);
        addSupportedPair(0x1F53f4972AAc7985A784C84f739Be4d73FB6d14f, PANCAKE_MASTER_CONTRACT, 0x7F67a7b681f3655C1b247068a9C977EcdeDd0768, 1);
    }

    function addSupportedMaster(address _master, LiquidityPool _pool) internal {
        masterPools[_master] = _pool;
    }

    function addSupportedPair(address _pair, address _master, address _router, uint256 _pid) internal {
        require(!pairTokenExists[_pair], "Liquity pair token has exists.");
        supportedPairs.push(_pair);
        pairTokenExists[_pair] = true;
        pairMasters[_pair] = _master;
        pairRouters[_pair] = _router;
        pairPids[_pair] = _pid;
    }

    modifier onlyGovernance() {
        require(governance == msg.sender, "Caller is not the governance.");
        _;
    }

    modifier onlyRebalancer() {
        require(rebalancer == msg.sender, "Caller is not the rebalancer.");
        _;
    }

    modifier onlyFundManager() {
        require(fundManager == msg.sender, "Caller is not the fundManager.");
        _;
    }

    function setGovernance(address _governance) external onlyOwner {
        governance = _governance;
        emit FundGovernanceSet(_governance);
    }

    function setRebalancer(address _rebalancer) external onlyGovernance {
        rebalancer = _rebalancer;
        emit FundRebalancerSet(_rebalancer);
    }

    function setMigrator(address _migrator) external onlyGovernance {
        migrator = _migrator;
        emit FundMigratorSet(_migrator);
    }

    function setFundManager(address _fundManager) external onlyGovernance {
        fundManager = _fundManager;
        emit FundManagerSet(_fundManager);
    }

    function _approveTo(address _token, address _receiver, uint256 _amount) internal {
        require(_token != address(0), "Invalid erc20 token contract.");
        IERC20 token = IERC20(_token);
        uint256 allowance = token.allowance(address(this), _receiver);
        if (allowance == _amount) 
            return;

        if (_amount > 0 && allowance > 0) 
            token.approve(_receiver, 0);

        token.approve(_receiver, _amount);
        emit ApproveTo(_token, _receiver, _amount);
    }

    function approveTo(address _token, address _receiver, uint256 _amount) external onlyGovernance {
        _approveTo(_token, _receiver, _amount);
    }

    function approveToMaster(address _pair, uint256 _amount) external onlyGovernance {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        _approveTo(_pair, master, _amount);
    }

    function approveToManager(address _token, uint256 _amount) external onlyGovernance {
        _approveTo(_token, fundManager, _amount);
    }

    function approveToMigrator(address _token, uint256 _amount) external onlyGovernance {
        _approveTo(_token, migrator, _amount);
    }

    function _depositToPool(address _pair, uint256 _amount) internal {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        LiquidityPool pool = masterPools[master];
        uint256 pid = pairPids[_pair];
        if (pool == LiquidityPool.BakeryPool) IBakeryMaster(master).deposit(_pair, _amount);
        else if (pool == LiquidityPool.MdexPool) IMdexMaster(master).deposit(pid, _amount);
        else if (pool == LiquidityPool.PancakePool) IPancakeMaster(master).deposit(pid, _amount);
        else revert("Invalid pool index.");
        emit DepositToPool(_pair, _amount);
    }

    // deposit by rebalancer
    function depositToPool(address _pair, uint256 _amount) external onlyRebalancer {
        _depositToPool(_pair, _amount);
    }

    // deposit by fund manager
    function depositToPoolByManager(address _pair, uint256 _amount) external onlyFundManager {
        _depositToPool(_pair, _amount);
    }

    function _withdrawFromPool(address _pair, uint256 _amount) internal {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        LiquidityPool pool = masterPools[master];
        uint256 pid = pairPids[_pair];
        if (pool == LiquidityPool.BakeryPool) IBakeryMaster(master).withdraw(_pair, _amount);
        else if (pool == LiquidityPool.MdexPool) IMdexMaster(master).withdraw(pid, _amount);
        else if (pool == LiquidityPool.PancakePool) IPancakeMaster(master).withdraw(pid, _amount);
        else revert("Invalid pool index.");
        emit WithdrawFromPool(_pair, _amount);
    }

    // withdraw by rebalancer
    function withdrawFromPool(address _pair, uint256 _amount) external onlyRebalancer {
        _withdrawFromPool(_pair, _amount);
    }

    // withdraw by fund manager
    function withdrawFromPoolByManager(address _pair, uint256 _amount) external onlyFundManager {
        _withdrawFromPool(_pair, _amount);
    }

    function _split(
        address _pair, 
        uint256 _liquidity, 
        uint256 _deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address router = pairRouters[_pair];
        address token0 = ISwapV2Pair(_pair).token0();
        address token1 = ISwapV2Pair(_pair).token1();
        (amount0, amount1) = ISwapV2Router(router).removeLiquidity(token0, token1, _liquidity, 1, 1, address(this), _deadline);
    }

    // remove liquity by rebalancer, which split the liquity to token0 and token1
    function split(
        address _pair, 
        uint256 _liquidity, 
        uint256 _deadline
    ) external onlyRebalancer returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _split(_pair, _liquidity, _deadline);
    }

    // remove liquity by fund manager, which split the liquity to token0 and token1
    function splitByManager(
        address _pair, 
        uint256 _liquidity, 
        uint256 _deadline
    ) external onlyFundManager returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _split(_pair, _liquidity, _deadline);
    }

    function _compose(
        address _pair, 
        uint256 _desiredAmount0, 
        uint256 _desiredAmount1, 
        uint256 _deadline
    ) internal returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address router = pairRouters[_pair];
        address token0 = ISwapV2Pair(_pair).token0();
        address token1 = ISwapV2Pair(_pair).token1();
        (amount0, amount1, liquidity) = ISwapV2Router(router).addLiquidity(token0, token1, _desiredAmount0, _desiredAmount1, 1, 1, address(this), _deadline);
    }

    // add liquity by rebalancer, which compose token0 and token1 into liquity
    function compose(
        address _pair, 
        uint256 _desiredAmount0, 
        uint256 _desiredAmount1, 
        uint256 _deadline
    ) external onlyRebalancer returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        (amount0, amount1, liquidity) = _compose(_pair, _desiredAmount0, _desiredAmount1, _deadline);
    }

    // add liquity by fund manager, which compose token0 and token1 into liquity
    function composeByManager(
        address _pair, 
        uint256 _desiredAmount0, 
        uint256 _desiredAmount1, 
        uint256 _deadline
    ) external onlyFundManager returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        (amount0, amount1, liquidity) = _compose(_pair, _desiredAmount0, _desiredAmount1, _deadline);
    }

    // rebalance the liquity from a pool to another
    function rebalance(
        address _oldPair, 
        address _newPair, 
        uint256 _liquidity, 
        uint256 _deadline
    ) external onlyRebalancer returns (uint256 newLiquidity) {
        require(pairTokenExists[_oldPair] && pairTokenExists[_newPair], "Invalid liquity pair contract.");
        address oldRouter = pairRouters[_oldPair];
        address newRouter = pairRouters[_newPair];
        address token0 = ISwapV2Pair(_oldPair).token0();
        address token1 = ISwapV2Pair(_oldPair).token1();
        newLiquidity = IMigrator(migrator).migrate(oldRouter, newRouter, token0, token1, _liquidity, _deadline);
        emit Rebalance(_liquidity, newLiquidity);
    }

    // get the contract balance by token
    function getTokenBalance(address _token) external view returns (uint256) {
        require(_token != address(0), "Invalid ERC20 token contract.");
        return IERC20(_token).balanceOf(address(this));
    }

    // get the address of reward token by pair
    function getRewardToken(address _pair) external view returns (address) {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        LiquidityPool pool = masterPools[master];
        if (pool == LiquidityPool.BakeryPool) return IBakeryMaster(master).bake();
        else if (pool == LiquidityPool.MdexPool) return IMdexMaster(master).mdx();
        else if (pool == LiquidityPool.PancakePool) return IPancakeMaster(master).cake();
        else revert("Invalid pool index.");
    }

    // get the amount of reward token by pair
    function getPoolReward(address _pair) external view returns (uint256) {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        LiquidityPool pool = masterPools[master];
        uint256 pid = pairPids[_pair];
        if (pool == LiquidityPool.BakeryPool) return IBakeryMaster(master).pendingBake(_pair, address(this));
        else if (pool == LiquidityPool.MdexPool) return IMdexMaster(master).pending(pid, address(this));
        else if (pool == LiquidityPool.PancakePool) return IPancakeMaster(master).pendingCake(pid, address(this));
        else revert("Invalid pool index.");
    }

    // get the amount of principal token(liquity token) by pair
    function getPoolPrincipal(address _pair) external view returns (uint256 amount) {
        require(pairTokenExists[_pair], "Invalid liquity pair contract.");
        address master = pairMasters[_pair];
        LiquidityPool pool = masterPools[master];
        uint256 pid = pairPids[_pair];
        if (pool == LiquidityPool.BakeryPool) (amount,) = IBakeryMaster(master).poolUserInfoMap(_pair, address(this));
        else if (pool == LiquidityPool.MdexPool) (amount,) = IMdexMaster(master).userInfo(pid, address(this));
        else if (pool == LiquidityPool.PancakePool) (amount,) = IPancakeMaster(master).userInfo(pid, address(this));
        else revert("Invalid pool index.");
    }

    // get the supported pair tokens
    function getSupportedPairs() external view returns (address[] memory pairs) {
        pairs = new address[](supportedPairs.length);
        for (uint256 i = 0; i < supportedPairs.length; i++) {
            pairs[i] = supportedPairs[i];
        }
    }
}
