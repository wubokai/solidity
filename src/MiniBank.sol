// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

contract MiniBank {

    uint256 public totalDeposits;

    address public owner;

 
    mapping(address=> uint256) public balances;
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Skim(address indexed to, uint256 amount);

    modifier onlyOwner(){
        require(msg.sender == owner,"not owner");
        _;
    }

    constructor(){
        owner = msg.sender;
    }

    function deposit() external payable{
        balances[msg.sender] +=msg.value;
        totalDeposits += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external{
        
        require(balances[msg.sender]>=amount,"not to do");

        balances[msg.sender] -= amount;
        totalDeposits -= amount;

        (bool ok,)=msg.sender.call{value:amount}("");
        require(ok,"valid");
        

        emit Withdraw(msg.sender, amount);

    }

    function balanceOf() external view returns(uint256){

            return balances[msg.sender];

    }

    function excess() public view returns(uint256){

            if(address(this).balance<totalDeposits){
                return 0;
            }
            return address(this).balance - totalDeposits;

    }

    function accountedBalance() external view returns(uint256){

        return totalDeposits;

    }
    

    function skim(address payable tos) external onlyOwner() returns(uint256 amount){
            amount = excess();
            require(amount>0,"no excess");
            (bool ok,) = tos.call{value: amount}("");
            require(ok,"failed");
            emit Skim(tos, amount);

    }


}