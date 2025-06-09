// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC721/IERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/Pausable.sol";

contract NakabozoStaking is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Struct to store staking information per token
    struct TokenStakeInfo {
        uint256 stakingStartTime;
        uint256 lastClaimTime;
        uint256 accumulatedRewards;
    }

    // Contract addresses
    IERC721 public nftContract;
    IERC20 public rewardToken;

    // Staking parameters
    uint256 public constant defaultRate = 41666666666666666666; // 41.67 tokens per hour per NFT
    uint256 public constant timeUnit = 1 days;
    uint256 public defaultStakePeriod = 7 days;
    uint256 public constant maxStakesPerUser = 100;

    // Mappings to store staking information
    mapping(address => uint256[]) public userStakedTokens;
    mapping(uint256 => TokenStakeInfo) public tokenStakeInfo;
    mapping(uint256 => address) public stakedTokens;
    mapping(address => uint256) public userStakeCount;

    // Events
    event nftStaked(address indexed user, uint256[] tokenIds);
    event nftUnstaked(address indexed user, uint256[] tokenIds);
    event rewardsClaimed(address indexed user, uint256 amount);
    event rewardPoolLow(uint256 currentBalance, uint256 requiredAmount);

    constructor(address _nftContract, address _rewardToken) {
        nftContract = IERC721(_nftContract);
        rewardToken = IERC20(_rewardToken);
    }

    // Pause/Unpause functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Function to stake NFTs
    function stakeNFTs(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "No tokens provided");
        require(userStakeCount[msg.sender] + tokenIds.length <= maxStakesPerUser, "Exceeds max stakes per user");
        
        // Check if user has approved the contract
        require(nftContract.isApprovedForAll(msg.sender, address(this)), "Contract not approved");

        // Check for duplicates
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = i + 1; j < tokenIds.length; j++) {
                require(tokenIds[i] != tokenIds[j], "Duplicate token IDs");
            }
        }

        // Transfer NFTs to contract
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(nftContract.ownerOf(tokenIds[i]) == msg.sender, "Not token owner");
            require(stakedTokens[tokenIds[i]] == address(0), "Token already staked");
            
            nftContract.transferFrom(msg.sender, address(this), tokenIds[i]);
            stakedTokens[tokenIds[i]] = msg.sender;
            userStakedTokens[msg.sender].push(tokenIds[i]);
            userStakeCount[msg.sender]++;
            
            tokenStakeInfo[tokenIds[i]] = TokenStakeInfo({
                stakingStartTime: block.timestamp,
                lastClaimTime: block.timestamp,
                accumulatedRewards: 0
            });
        }

        emit nftStaked(msg.sender, tokenIds);
    }

    // Function to unstake NFTs
    function unstakeNFTs(uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(tokenIds.length > 0, "No tokens provided");
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(stakedTokens[tokenIds[i]] == msg.sender, "Not staked by user");
            
            // Transfer NFT back to user
            nftContract.transferFrom(address(this), msg.sender, tokenIds[i]);
            delete stakedTokens[tokenIds[i]];
            delete tokenStakeInfo[tokenIds[i]];
            userStakeCount[msg.sender]--;
        }

        // Remove tokens from user's staked tokens array
        uint256[] storage userTokens = userStakedTokens[msg.sender];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = 0; j < userTokens.length; j++) {
                if (userTokens[j] == tokenIds[i]) {
                    userTokens[j] = userTokens[userTokens.length - 1];
                    userTokens.pop();
                    break;
                }
            }
        }

        emit nftUnstaked(msg.sender, tokenIds);
    }

    // Function to calculate rewards for a token
    function calculateTokenRewards(uint256 tokenId) public view returns (uint256) {
        TokenStakeInfo storage info = tokenStakeInfo[tokenId];
        if (info.stakingStartTime == 0) return 0;

        uint256 stakingDuration = block.timestamp - info.lastClaimTime;
        if (stakingDuration < defaultStakePeriod) return 0;

        return (defaultRate * stakingDuration) / timeUnit;
    }

    // Function to calculate total rewards for a user
    function calculateRewards(address account) public view returns (uint256) {
        uint256[] storage userTokens = userStakedTokens[account];
        uint256 totalRewards = 0;

        for (uint256 i = 0; i < userTokens.length; i++) {
            totalRewards += calculateTokenRewards(userTokens[i]);
        }

        return totalRewards;
    }

    // Function to check if staking period is complete
    function isStakingPeriodComplete(address account) public view returns (bool) {
        uint256[] storage userTokens = userStakedTokens[account];
        if (userTokens.length == 0) return false;

        for (uint256 i = 0; i < userTokens.length; i++) {
            TokenStakeInfo storage info = tokenStakeInfo[userTokens[i]];
            if (block.timestamp - info.lastClaimTime >= defaultStakePeriod) {
                return true;
            }
        }
        return false;
    }

    // Function to claim rewards
    function claimRewards() external nonReentrant whenNotPaused {
        require(isStakingPeriodComplete(msg.sender), "Minimum staking period (7 days) not met");
        
        uint256[] storage userTokens = userStakedTokens[msg.sender];
        uint256 totalRewards = 0;

        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 tokenRewards = calculateTokenRewards(userTokens[i]);
            if (tokenRewards > 0) {
                tokenStakeInfo[userTokens[i]].lastClaimTime = block.timestamp;
                tokenStakeInfo[userTokens[i]].accumulatedRewards += tokenRewards;
                totalRewards += tokenRewards;
            }
        }

        require(totalRewards > 0, "No rewards to claim");

        // Check reward pool balance
        uint256 poolBalance = rewardToken.balanceOf(address(this));
        if (poolBalance < totalRewards) {
            emit rewardPoolLow(poolBalance, totalRewards);
            revert("Insufficient reward pool balance");
        }

        // Transfer rewards
        rewardToken.safeTransfer(msg.sender, totalRewards);

        emit rewardsClaimed(msg.sender, totalRewards);
    }

    // Function to get stake info for a user
    function getStakeInfo(address account) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory stakingStartTimes,
        uint256[] memory lastClaimTimes,
        uint256[] memory accumulatedRewards,
        uint256 totalRewards
    ) {
        uint256[] storage userTokens = userStakedTokens[account];
        tokenIds = new uint256[](userTokens.length);
        stakingStartTimes = new uint256[](userTokens.length);
        lastClaimTimes = new uint256[](userTokens.length);
        accumulatedRewards = new uint256[](userTokens.length);

        for (uint256 i = 0; i < userTokens.length; i++) {
            TokenStakeInfo storage info = tokenStakeInfo[userTokens[i]];
            tokenIds[i] = userTokens[i];
            stakingStartTimes[i] = info.stakingStartTime;
            lastClaimTimes[i] = info.lastClaimTime;
            accumulatedRewards[i] = info.accumulatedRewards;
        }

        totalRewards = calculateRewards(account);
    }

    // Function to get rewards per unit time
    function getRewardsPerUnitTime() external pure returns (uint256) {
        return defaultRate;
    }

    // Function to get time unit
    function getTimeUnit() external pure returns (uint256) {
        return timeUnit;
    }

    // Function to get default stake period
    function getDefaultStakePeriod() external view returns (uint256) {
        return defaultStakePeriod;
    }

    // Function to exit staking
    function exit() external whenNotPaused {
        uint256[] storage userTokens = userStakedTokens[msg.sender];
        require(userTokens.length > 0, "No NFTs staked");
        
        // Calculate and transfer rewards
        uint256 totalRewards = calculateRewards(msg.sender);
        if (totalRewards > 0) {
            uint256 poolBalance = rewardToken.balanceOf(address(this));
            if (poolBalance < totalRewards) {
                emit rewardPoolLow(poolBalance, totalRewards);
                revert("Insufficient reward pool balance");
            }
            rewardToken.safeTransfer(msg.sender, totalRewards);
            emit rewardsClaimed(msg.sender, totalRewards);
        }
        
        // Unstake all NFTs
        uint256[] memory tokenIds = userTokens;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nftContract.transferFrom(address(this), msg.sender, tokenIds[i]);
            delete stakedTokens[tokenIds[i]];
            delete tokenStakeInfo[tokenIds[i]];
        }
        
        delete userStakedTokens[msg.sender];
        userStakeCount[msg.sender] = 0;
    }

    // Function to get user's pending rewards
    function getUserPendingRewards(address user) external view returns (uint256) {
        return calculateRewards(user);
    }

    // Admin functions
    function setMinimumStakingPeriod(uint256 newPeriod) external onlyOwner {
        defaultStakePeriod = newPeriod;
    }

    function emergencyUnstake(address user, uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(stakedTokens[tokenIds[i]] == user, "Token not staked by user");
            nftContract.transferFrom(address(this), user, tokenIds[i]);
            delete stakedTokens[tokenIds[i]];
            delete tokenStakeInfo[tokenIds[i]];
            userStakeCount[user]--;
        }
        
        // Remove tokens from user's staked tokens array
        uint256[] storage userTokens = userStakedTokens[user];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = 0; j < userTokens.length; j++) {
                if (userTokens[j] == tokenIds[i]) {
                    userTokens[j] = userTokens[userTokens.length - 1];
                    userTokens.pop();
                    break;
                }
            }
        }
        
        emit nftUnstaked(user, tokenIds);
    }

    // View functions
    function getStakedTokenOwner(uint256 tokenId) external view returns (address) {
        return stakedTokens[tokenId];
    }

    function getStakedTokenIds(address user) external view returns (uint256[] memory) {
        return userStakedTokens[user];
    }

    // Security functions
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(rewardToken), "Cannot recover reward token");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function recoverERC721(address token, uint256 tokenId) external onlyOwner {
        require(token != address(nftContract), "Cannot recover staked NFTs");
        IERC721(token).transferFrom(address(this), owner(), tokenId);
    }

    function emergencyWithdrawRewards() external onlyOwner {
        uint256 balance = rewardToken.balanceOf(address(this));
        rewardToken.safeTransfer(owner(), balance);
    }

    // Reward pool functions
    function depositRewards(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function getRewardPoolBalance() external view returns (uint256) {
        return rewardToken.balanceOf(address(this));
    }

    function getRewardToken() external view returns (address) {
        return address(rewardToken);
    }
} 