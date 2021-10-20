const VaultManager = artifacts.require('VaultManager');
const VaultController = artifacts.require('VaultController');
const VaultStrategy = artifacts.require('VaultStrategy');

module.exports = function (deployer, network, accounts) {
  deployer.then(async () => {
    let basePair = '0xcde42733E82f663B671575bC30183709DD89D2a9';
    let withdrawalFeeRate = '3000000000000000';
    let maxTotalSupply = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

    // deploy vaultManager
    await deployer.deploy(VaultManager, basePair, withdrawalFeeRate, maxTotalSupply);
    const vaultManager = await VaultManager.deployed();
    console.log('vaultManager address:', vaultManager.address);
    console.log('finish deploy VaultManager contracts.');

    // deploy vaultController
    await deployer.deploy(VaultController);
    const vaultController = await VaultController.deployed();
    console.log('vaultController address:', vaultController.address);
    console.log('finish deploy VaultController contracts.');

    // deploy vaultStrategy
    await deployer.deploy(VaultStrategy, vaultController.address);
    const vaultStrategy = await VaultStrategy.deployed();
    console.log('vaultStrategy address:', vaultStrategy.address);
    console.log('finish deploy VaultStrategy contracts.');

    // init vaultManager
    await vaultManager.setVaultController(vaultController.address);
    console.log('finish set controller.');

    // init vaultController
    // let strategy = '0x9Ba9Ae032a2709efb6eB5651b78058F19f01A38C';
    await vaultController.setManager(vaultManager.address);
    await vaultController.setStrategy(vaultStrategy.address);
    console.log('finish set manager and strategy.');

    let pancakePair = '0xcde42733E82f663B671575bC30183709DD89D2a9';
    let bakeryPair = '0x34be5Cb31DD28839Dab7886f19AD9c3bCd26B7a1';
    let wbnb = '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd';
    let busd = '0x8301F2213c0eeD49a7E28Ae4c3e91722919B8B47';
    let maxUint256 = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

    await vaultController.approveToMaster(pancakePair, maxUint256);
    await vaultController.approveToMaster(bakeryPair, maxUint256);
    console.log('finish approve pair to master.');

    await vaultController.approveToManager(wbnb, maxUint256);
    await vaultController.approveToManager(busd, maxUint256);
    console.log('finish approve token to manager.');
    });
};
