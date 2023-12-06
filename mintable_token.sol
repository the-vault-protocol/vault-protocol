// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

interface IERC20 {

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address delegate) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address delegate, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed recipient, uint256 value);

}

contract MintableToken is IERC20 {

    string private _name;
    string private _symbol;
    uint8 private constant _decimals = 18;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    uint256 private totalSupply_ = 0;

    address private _contract_owner;

    event Mint(address recipient, uint256 amount);
    event Burn(address owner, uint256 amount);

    constructor(string memory name_, string memory symbol_) {

        // set token parameters
        _name   = name_;
        _symbol = symbol_;

        // total supply is owned by contract creator
        balances[msg.sender] = totalSupply_;

        // set owner
        _contract_owner = msg.sender;

    }

    // ERC20 Getters

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return totalSupply_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address delegate) public view override returns (uint256) {
        return allowances[owner][delegate];
    }

    // Custom Getter

    function getOwner() public view returns (address) {
        return _contract_owner;
    }

    // ERC20 Functions

    // transfer tokens to receiver
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        
        require(amount <= balances[msg.sender]);
        
        balances[msg.sender] = balances[msg.sender] - amount;
        balances[recipient]  = balances[recipient] + amount;
       
        emit Transfer(msg.sender, recipient, amount);

        return true;

    }

    // allows the delegate to spend tokens on your behalf
    function approve(address delegate, uint256 amount) public override returns (bool) {
        allowances[msg.sender][delegate] = amount;
        emit Approval(msg.sender, delegate, amount);
        return true;
    }

    // delegate transfers tokens from owner to recipient
    function transferFrom(address owner, address recipient, uint256 amount) public override returns (bool) {
        
        // owner has enough tokens
        require(amount <= balances[owner]);

        // owner has allowed delegate to send enough tokens
        require(amount <= allowances[owner][msg.sender]);

        balances[owner]               = balances[owner] - amount;
        allowances[owner][msg.sender] = allowances[owner][msg.sender] - amount;
        balances[recipient]           = balances[recipient] + amount;

        emit Transfer(owner, recipient, amount);

        return true;

    }

    // Custom Functions

    function transferOwnership(address newOwner) public returns (bool) {

        // verify current ownership
        require(msg.sender == _contract_owner);

        _contract_owner = newOwner;

        return true;

    }

    function mint(address recipient, uint256 amount) public returns (bool) {

        // only the contract owner can mint new tokens
        require(msg.sender == _contract_owner);

        totalSupply_ = totalSupply_ + amount;
        balances[recipient] = balances[recipient] + amount;

        // emit mint event
        emit Mint(recipient, amount);

        return true;
    }

    function burn(address owner, uint256 amount) public returns (bool) {

        // only the contract owner can burn tokens
        require(msg.sender == _contract_owner);

        // target account owner has enough tokens
        require(amount <= balances[owner]);

        totalSupply_ = totalSupply_ - amount;
        balances[owner] = balances[owner] - amount;

        // emit burn event
        emit Burn(owner, amount);

        return true;
    }

}
