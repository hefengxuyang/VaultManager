// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IMdexMaster {    
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function emergencyWithdraw(uint256 _pid) external;

    function mdx() external view returns (address);

    function pending(uint256 _pid, address _user) external view returns (uint256);

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
}
