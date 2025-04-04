// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

error AlreadyClaimed();
error InvalidProof();
error ClaimingNotStarted();
error ClaimingEnded();
error InsufficientBalance();
error ZeroAddress();
error ZeroAmount();
error ArrayLengthMismatch();

contract MerkleDistributor is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public immutable token;
    bytes32 public merkleRoot;
    uint256 public dropAmount;
    
    // Configurable claiming window
    uint256 public claimStart;
    uint256 public claimEnd;
    
    // Stats tracking
    uint256 public totalClaimed;
    uint256 public totalRecipients;
    
    mapping(address => bool) private addressClaimed;

    event Claimed(address indexed claimant, uint256 amount);
    event BatchProcessed(uint256 successCount, uint256 skipCount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event DropAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event ClaimPeriodSet(uint256 startTime, uint256 endTime);
    event EmergencyWithdrawal(address token, address recipient, uint256 amount);
    event DistributionAttempted(address recipient, bool success, string reason);

    constructor(
        address token_,
        bytes32 merkleRoot_,
        uint256 dropAmount_,
        uint256 claimStart_,
        uint256 claimEnd_,
        address initialowner
    ) Ownable(initialowner) {
        if (token_ == address(0)) revert ZeroAddress();
        if (dropAmount_ == 0) revert ZeroAmount();
        
        token = token_;
        merkleRoot = merkleRoot_;
        dropAmount = dropAmount_;
        
        // Set claim period
        claimStart = claimStart_ > 0 ? claimStart_ : block.timestamp;
        claimEnd = claimEnd_ > claimStart ? claimEnd_ : type(uint256).max;
        
        emit ClaimPeriodSet(claimStart, claimEnd);
    }

    /**
     * @notice Claims tokens for the calling address
     * @param merkleProof The merkle proof of inclusion in the airdrop
     */
    function claim(bytes32[] calldata merkleProof) external nonReentrant whenNotPaused {
        // Check if claiming is active
        if (block.timestamp < claimStart) revert ClaimingNotStarted();
        if (block.timestamp > claimEnd) revert ClaimingEnded();
        
        // Check if already claimed
        if (addressClaimed[msg.sender]) revert AlreadyClaimed();
        
        // Verify the merkle proof
        bytes32 node = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) revert InvalidProof();
        
        // Verify contract has enough tokens
        if (IERC20(token).balanceOf(address(this)) < dropAmount) revert InsufficientBalance();
        
        // Mark as claimed
        addressClaimed[msg.sender] = true;
        totalClaimed += dropAmount;
        totalRecipients += 1;
        
        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, dropAmount);
        
        emit Claimed(msg.sender, dropAmount);
    }
    
    /**
     * @notice Admin function to distribute tokens to multiple recipients in one transaction
     * @param recipients Array of recipient addresses
     * @param proofs Array of merkle proofs corresponding to each recipient
     */
    function batchDistribute(
        address[] calldata recipients,
        bytes32[][] calldata proofs
    ) external onlyOwner nonReentrant whenNotPaused {
        // Check if claiming is active
        if (block.timestamp < claimStart) revert ClaimingNotStarted();
        if (block.timestamp > claimEnd) revert ClaimingEnded();
        
        // Ensure arrays have the same length  
        if (recipients.length != proofs.length) revert ArrayLengthMismatch();
        
        // Check contract balance
        uint256 requiredBalance = dropAmount * recipients.length;
        if (IERC20(token).balanceOf(address(this)) < requiredBalance) 
            revert InsufficientBalance();
        
        uint256 successCount = 0;
        uint256 skipCount = 0;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            
            // Skip if null address
            if (recipient == address(0)) {
                emit DistributionAttempted(recipient, false, "Null address");
                skipCount++;
                continue;
            }
            
            // Skip if already claimed
            if (addressClaimed[recipient]) {
                emit DistributionAttempted(recipient, false, "Already claimed");
                skipCount++;
                continue;
            }
            
            // Verify the merkle proof
            bytes32 node = keccak256(abi.encodePacked(recipient));
            bool isValid = MerkleProof.verify(proofs[i], merkleRoot, node);
            
            if (!isValid) {
                emit DistributionAttempted(recipient, false, "Invalid proof");
                skipCount++;
                continue;
            }
            
            // Mark as claimed
            addressClaimed[recipient] = true;      
            totalRecipients += 1;
            totalClaimed += dropAmount;
            
            // Transfer tokens - IMPORTANT: Transfer to the recipient, not msg.sender
            IERC20(token).safeTransfer(recipient, dropAmount);
            
            emit Claimed(recipient, dropAmount);
            emit DistributionAttempted(recipient, true, "Success");
            successCount++;
        }
        
        emit BatchProcessed(successCount, skipCount);
    }

    /**
     * @notice Checks if an address has already claimed tokens
     * @param user Address to check
     * @return Whether the address has claimed its tokens
     */
    function isClaimed(address user) external view returns (bool) {
        return addressClaimed[user];
    }
    
    /**
     * @notice Returns information about the claiming status
     * @return isActive Whether claiming is currently active
     * @return remainingTime Time until claiming ends (0 if already ended)
     */
    function claimStatus() external view returns (bool isActive, uint256 remainingTime) {
        isActive = block.timestamp >= claimStart && block.timestamp <= claimEnd && !paused();
        
        if (block.timestamp < claimEnd) {
            remainingTime = claimEnd - block.timestamp;
        } else {
            remainingTime = 0;
        }
    }
    
    /**
     * @notice Returns the remaining tokens in the contract
     * @return The current balance of tokens in the contract
     */
    function remainingTokens() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Updates the merkle root (for fixing issues or updating eligible addresses)
     * @param newMerkleRoot The new merkle root
     */
    function updateMerkleRoot(bytes32 newMerkleRoot) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, newMerkleRoot);
        merkleRoot = newMerkleRoot;
    }
    
    /**
     * @notice Updates the drop amount per recipient
     * @param newDropAmount The new amount each recipient receives
     */
    function updateDropAmount(uint256 newDropAmount) external onlyOwner {
        if (newDropAmount == 0) revert ZeroAmount();
        emit DropAmountUpdated(dropAmount, newDropAmount);
        dropAmount = newDropAmount;
    }
    
    /**
     * @notice Sets or updates the claim period
     * @param newClaimStart The new claim start time
     * @param newClaimEnd The new claim end time
     */
    function setClaimPeriod(uint256 newClaimStart, uint256 newClaimEnd) external onlyOwner {
        if (newClaimStart > 0) {
            claimStart = newClaimStart;
        }
        
        if (newClaimEnd > claimStart) {
            claimEnd = newClaimEnd;
        }
        
        emit ClaimPeriodSet(claimStart, claimEnd);
    }
    
    /**
     * @notice Pauses the contract (emergency use)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Emergency withdrawal of tokens in case of critical issues
     * @param tokenAddress The token to withdraw (either airdrop token or other accidentally sent tokens)
     * @param recipient The address to send the tokens to
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(
        address tokenAddress,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        
        IERC20(tokenAddress).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(tokenAddress, recipient, amount);
    }
}