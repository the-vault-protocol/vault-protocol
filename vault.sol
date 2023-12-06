// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import "./mintable_token.sol";

interface ERC20Interface {

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

contract Vault {

    struct Dispute {
        address initiator;
        uint256 initiationAmount;
        uint256 endTime;
        uint256 acceptWeight; // votes to accept dispute
        uint256 declineWeight; // votes to decline dispute
        bool open;
    }

    struct Vote {
        address voter;
        bool vote;
        uint256 weight;
    }

    // oracle
    string private oracle_condition;

    // minting & redemption
    address private base_token_address;
    ERC20Interface private base_token_contract;

    MintableToken private c_token_contract;
    MintableToken private i_token_contract;

    // governance
    address private governance_token_address;
    ERC20Interface private governance_token_contract;

    // unlocking
    bool private locked;
    Dispute private dispute;
    Vote[] private votes;
    uint256 private disputeDuration = 604800;
    uint256 private initiationAmountDenominator = 4; // defines amount of outstanding iTokens needed for dispute initiation

    mapping(address => uint256) private resolvingBaseTokenReward;
    mapping(address => uint256) private resolvingGovernanceTokenReward;

    // fees
    uint256 private accruedFees = 0; // total of all fees ever accrued
    uint256 private remainingFees = 0; // current fees held by the contract

    mapping(address => uint256) private accruedFeesAtLastWithdrawal;

    // events
    event ConvertEvent(address user_, uint256 amount_, uint256 mintAmount_);
    event RedeemEvent(address user_, uint256 redeemAmount_, bool locked_);
    event InitiateDisputeEvent(address user_, uint256 disputeInitiationAmount_, uint256 disputeDuration);
    event ResolveDisputeEvent(address user_, bool locked_);

    constructor(address _base_token_address, address _governance_token_address, string memory _oracle_condition) {

        // vaults are always locked by default
        locked = true;

        // instantiate minting & redemption tokens
        base_token_address  = _base_token_address;
        base_token_contract = ERC20Interface(base_token_address);

        c_token_contract = new MintableToken("", "");
        i_token_contract = new MintableToken("", "");

        // set oracle condition
        oracle_condition = _oracle_condition;

        // instantiate governance token
        governance_token_address  = _governance_token_address;
        governance_token_contract = ERC20Interface(governance_token_address);

        // instantiate closed dispute
        dispute = Dispute({
            initiator: address(this), 
            initiationAmount: 0, 
            endTime: 0, 
            acceptWeight: 0, 
            declineWeight: 0, 
            open: false
        });

    }

    // Getters

    function getBaseTokenAddress() public view returns (address) {
        return base_token_address;
    }

    function getGovernanceTokenAddress() public view returns (address) {
        return governance_token_address;
    }

    function getCTokenAddress() public view returns (address) {
        return address(c_token_contract);
    }

    function getITokenAddress() public view returns (address) {
        return address(i_token_contract);
    }

    function getLockedState() public view returns (bool) {
        return locked;
    }

    function getAccruedFees() public view returns (uint256) {
        return accruedFees;
    }

    function getRemainingFees() public view returns (uint256) {
        return remainingFees;
    }

    function getOwedFees() public view returns (uint256) {

        // check if new fees where accrued since the user's last withdrawal
        uint256 newFees = accruedFees - accruedFeesAtLastWithdrawal[msg.sender];

        // calculate the share of the new fees that belong to the user
        uint256 senderGovernanceTokenBalance = governance_token_contract.balanceOf(msg.sender);
        uint256 totalGovernanceTokenSupply   = governance_token_contract.totalSupply();

        // solidity always rounds down, so the contract can never send to many tokens
        uint256 userFeeShare = (newFees * senderGovernanceTokenBalance) / totalGovernanceTokenSupply;

        return userFeeShare;

    }

    function getOwedBaseTokenRewards() public view returns (uint256) {

        return resolvingBaseTokenReward[msg.sender];

    }

    function getOwedGovernanceTokenRewards() public view returns (uint256) {

        return resolvingGovernanceTokenReward[msg.sender];

    }

    function getDisputeStatus() public view returns (bool) {
        return dispute.open;
    }

    function getDisputeEndTime() public view returns (uint256) {
        return dispute.endTime;
    }

    function getInitiationAmountDenominator() public view returns (uint256) {
        return initiationAmountDenominator;
    }

    function getOracleCondition() public view returns (string memory) {
        return oracle_condition;
    }

    // Minting & Redemption

    function convert(uint256 amount) public returns (bool) {

        // 1) receive X amount of ERC20 token
        // 2) deduct fees and store in vault for distribution
        // 3) issue cTokens and iTokens to sender

        // do not need to check allowance since operation fails if not enough allowance
        base_token_contract.transferFrom(msg.sender, address(this), amount);

        // deduct fees
        uint256 mintAmount = amount - (amount / 100);
        accruedFees += amount - mintAmount;
        remainingFees += amount - mintAmount;

        // mint new tokens
        c_token_contract.mint(msg.sender, mintAmount);
        i_token_contract.mint(msg.sender, mintAmount);

        emit ConvertEvent(msg.sender, amount, mintAmount);

        return true;

    }

    function redeem(uint256 amount) public returns (bool) {

        // 1) receive cTokens and iTokens from sender (or only iTokens in case of default)
        // 2) burn cTokens and iTokens
        // 3) send original ERC20 tokens back to sender

        if (locked) {

            c_token_contract.burn(msg.sender, amount);
            i_token_contract.burn(msg.sender, amount);

            base_token_contract.transfer(msg.sender, amount);

        } else {

            i_token_contract.burn(msg.sender, amount);

            base_token_contract.transfer(msg.sender, amount);

        }

        emit RedeemEvent(msg.sender, amount, locked);

        return true;

    }

    // Vault Unlocking

    function initiateDispute() public returns (bool) {

        // everyone can initiate a dispute when they pay a dispute fee
        // if the dispute ends unresolved this fee is lost and paid to voters who voted against unlocking

        // a dispute can only be opened if there is no open dispute already
        require(!dispute.open);

        // to open a dispute, a fraction of all outstanding value needs to be deposited
        uint256 disputeInitiationAmount = i_token_contract.totalSupply() / initiationAmountDenominator;

        // do not need to check allowance since operation fails if not enough allowance
        base_token_contract.transferFrom(msg.sender, address(this), disputeInitiationAmount);

        // create new dispute
        dispute = Dispute({
            initiator: msg.sender, 
            initiationAmount: disputeInitiationAmount, 
            endTime: (block.timestamp + disputeDuration), 
            acceptWeight: 0,
            declineWeight: 0,
            open: true
        });

        // clear vote array
        delete votes;

        emit InitiateDisputeEvent(msg.sender, disputeInitiationAmount, disputeDuration);

        return true;

    }


    function vote(bool voteValue, uint256 voteWeight) public returns (bool) {

        // it is allowed to vote multiple times

        // dispute needs to be open and endTime has not come yet
        require(dispute.open);
        require(block.timestamp <= dispute.endTime);

        // transfer vote weight to contract custody
        governance_token_contract.transferFrom(msg.sender, address(this), voteWeight);

        // create vote
        votes.push(Vote({voter: msg.sender, vote: voteValue, weight: voteWeight}));
        
        // update dispute
        if (voteValue) {
            dispute.acceptWeight += voteWeight;
        }
        else {
            dispute.declineWeight += voteWeight;
        }

        return true;

    }


    function resolveDispute() public returns (bool) {

        // dispute needs to be open and endTime has come
        require(dispute.open);
        require(block.timestamp > dispute.endTime);

        // dispute was accepted
        if (dispute.acceptWeight > dispute.declineWeight) {

            // refund initiation amount
            base_token_contract.transfer(dispute.initiator, dispute.initiationAmount);

            // slash tokens of users who voted against unlocking and make them available for withdrawal
            for (uint i = 0; i < votes.length; i++) {
                if (votes[i].vote) {
                    resolvingGovernanceTokenReward[votes[i].voter] += (((dispute.declineWeight * votes[i].weight) / dispute.acceptWeight) + votes[i].weight);
                }
            }

            // unlock vault
            locked = false;

            // close dispute
            dispute.open = false;

        }
        // dispute was not accepted
        else {

            // slash initiation amount and tokens of users who voted for unlocking and make them available for withdrawal
            for (uint i = 0; i < votes.length; i++) {
                if (!votes[i].vote) {
                    resolvingGovernanceTokenReward[votes[i].voter] += (((dispute.acceptWeight * votes[i].weight) / dispute.declineWeight) + votes[i].weight);
                    resolvingBaseTokenReward[votes[i].voter] += (dispute.initiationAmount * votes[i].weight) / dispute.declineWeight;
                }
            }

            // close dispute
            dispute.open = false;

        }

        emit ResolveDisputeEvent(msg.sender, locked);

        return true;

    }


    function withdrawGovernanceTokenReward() public returns (bool) {

        // only withdraw amounts > 0
        require(resolvingGovernanceTokenReward[msg.sender] > 0);

        // send reward to user
        governance_token_contract.transfer(msg.sender, resolvingGovernanceTokenReward[msg.sender]);

        // set owed reward to 0
        resolvingGovernanceTokenReward[msg.sender] = 0;

        return true;

    }


    function withdrawBaseTokenReward() public returns (bool) {

        // only withdraw amounts > 0
        require(resolvingBaseTokenReward[msg.sender] > 0);

        // send reward to user
        base_token_contract.transfer(msg.sender, resolvingBaseTokenReward[msg.sender]);

        // set owed reward to 0
        resolvingBaseTokenReward[msg.sender] = 0;

        return true;

    }


    // Fee Withdrawal

    function withdrawOwedFees() public returns (bool) {

        // check if new fees where accrued since the user's last withdrawal
        uint256 newFees = accruedFees - accruedFeesAtLastWithdrawal[msg.sender];

        require(newFees > 0);

        // calculate the share of the new fees that belong to the user
        uint256 senderGovernanceTokenBalance = governance_token_contract.balanceOf(msg.sender);
        uint256 totalGovernanceTokenSupply   = governance_token_contract.totalSupply();

        // solidity always rounds down, so the contract can never send too many tokens
        uint256 userFeeShare = (newFees * senderGovernanceTokenBalance) / totalGovernanceTokenSupply;

        require (userFeeShare > 0);

        // transfer user fee share to user
        base_token_contract.transfer(msg.sender, userFeeShare);

        // update bookkeeping
        remainingFees -= userFeeShare;
        accruedFeesAtLastWithdrawal[msg.sender] = accruedFees;

        return true;

    }

}
