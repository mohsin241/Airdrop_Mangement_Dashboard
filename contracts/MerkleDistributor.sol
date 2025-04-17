// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

error AlreadyClaimed();
error InvalidProof();
error ClaimingEnded();
error InsufficientBalance();
error ZeroAddress();
error ZeroAmount();
error ArrayLengthMismatch();
error InvalidPhase();
error PhaseNotActive();

contract MerkleDistributorV2 is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Immutable token address
    address public immutable token;
    
    // Phase struct for better organization
    struct Phase {
        bytes32 merkleRoot;       // Merkle root for this phase
        uint64 dropAmount;        // Amount per claim for this phase (in smallest token units)
        uint64 endTime;           // End time for this phase
        uint64 recipientCount;    // Number of recipients who claimed in this phase
        uint64 phaseIndex;        // Phase index for identification
        bool active;              // Whether the phase is active
    }
    
    // Track phases
    Phase[] public phases;
    uint8 public currentPhaseId;
    
    // Track claims by phase - phaseId => address => claimed (1 = true, 0 = false)
    mapping(uint8 => mapping(address => uint256)) private addressClaimed;
    
    // Stats tracking
    uint128 public totalClaimed;
    uint128 public totalRecipients;
    
    // Events
    event Claimed(address indexed claimant, uint256 amount, uint8 phaseId);
    event BatchProcessed(uint256 successCount, uint256 skipCount, uint8 phaseId);
    event PhaseCreated(uint8 phaseId, bytes32 merkleRoot, uint256 dropAmount, uint256 endTime);
    event PhaseUpdated(uint8 phaseId, bytes32 merkleRoot, uint256 dropAmount, uint256 endTime);
    event PhaseActivated(uint8 phaseId);
    event PhaseDeactivated(uint8 phaseId);
    event EmergencyWithdrawal(address token, address recipient, uint256 amount);
    
    constructor(
        address token_,
        bytes32 initialMerkleRoot,
        uint256 initialDropAmount,
        uint256 initialEndTime,
        address initialOwner
    ) Ownable(initialOwner) {
        if (token_ == address(0)) revert ZeroAddress();
        if (initialDropAmount == 0) revert ZeroAmount();
        
        token = token_;
        
        // Create initial phase
        uint256 endTime = initialEndTime > block.timestamp ? initialEndTime : type(uint64).max;
        
        // Safe conversion to uint64 with overflow check
        if (initialDropAmount > type(uint64).max) revert("Drop amount too large");
        
        phases.push(Phase({
            merkleRoot: initialMerkleRoot,
            dropAmount: uint64(initialDropAmount),
            endTime: uint64(endTime),
            recipientCount: 0,
            phaseIndex: 0,
            active: true
        }));
        
        emit PhaseCreated(0, initialMerkleRoot, initialDropAmount, endTime);
        emit PhaseActivated(0);
    }
    
    /**
     * @notice Claims tokens for the calling address from the current phase
     * @param merkleProof The merkle proof of inclusion in the airdrop
     */
    function claim(bytes32[] calldata merkleProof) external nonReentrant whenNotPaused {
        _claimForPhase(currentPhaseId, merkleProof, msg.sender);
    }
    
    /**
     * @notice Claims tokens for a specific phase (if still active)
     * @param phaseId The phase ID to claim from
     * @param merkleProof The merkle proof of inclusion in the airdrop
     */
    function claimForPhase(uint8 phaseId, bytes32[] calldata merkleProof) external nonReentrant whenNotPaused {
        _claimForPhase(phaseId, merkleProof, msg.sender);
    }
    
    /**
     * @notice Internal claim function with phase support
     * @param phaseId The phase ID to claim from
     * @param merkleProof The merkle proof
     * @param recipient The address to receive tokens
     */
    function _claimForPhase(uint8 phaseId, bytes32[] calldata merkleProof, address recipient) internal {
        // Check phase exists
        if (phaseId >= phases.length) revert InvalidPhase();
        
        // Get phase data to reduce stack usage
        bytes32 merkleRoot = phases[phaseId].merkleRoot;
        uint64 dropAmount = phases[phaseId].dropAmount;
        uint64 endTime = phases[phaseId].endTime;
        bool phaseActive = phases[phaseId].active;
        
        // Check phase is active and not expired
        if (!phaseActive) revert PhaseNotActive();
        if (block.timestamp > endTime) revert ClaimingEnded();
        
        // Check if already claimed for this phase
        if (addressClaimed[phaseId][recipient] != 0) revert AlreadyClaimed();
        
        // Verify the merkle proof
        bytes32 node = keccak256(abi.encodePacked(recipient));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) revert InvalidProof();
        
        // Verify contract has enough tokens
        if (IERC20(token).balanceOf(address(this)) < dropAmount) revert InsufficientBalance();
        
        // Mark as claimed for this phase
        addressClaimed[phaseId][recipient] = 1;
        
        // Update counters
        _updateCounters(phaseId, dropAmount);
        
        // Transfer tokens
        IERC20(token).safeTransfer(recipient, dropAmount);
        
        emit Claimed(recipient, dropAmount, phaseId);
    }
    
    /**
     * @notice Helper function to update counters to reduce stack variables
     * @param phaseId The phase ID being claimed from
     * @param dropAmount The amount being claimed
     */
    function _updateCounters(uint8 phaseId, uint64 dropAmount) private {
        unchecked {
            phases[phaseId].recipientCount++;
            totalClaimed += dropAmount;
            totalRecipients++;
        }
    }
    
    /**
     * @notice Admin function to distribute tokens to multiple recipients in one transaction
     * @param phaseId The phase ID to process
     * @param recipients Array of recipient addresses
     * @param proofs Array of merkle proofs corresponding to each recipient
     */
    function batchDistribute(
        uint8 phaseId,
        address[] calldata recipients,
        bytes32[][] calldata proofs
    ) external onlyOwner nonReentrant whenNotPaused {
        // Check phase exists
        if (phaseId >= phases.length) revert InvalidPhase();
        
        // Get phase data to reduce stack usage
        bytes32 merkleRoot = phases[phaseId].merkleRoot;
        uint64 dropAmount = phases[phaseId].dropAmount;
        uint64 endTime = phases[phaseId].endTime;
        bool phaseActive = phases[phaseId].active;
        
        // Check phase is active and not expired
        if (!phaseActive) revert PhaseNotActive();
        if (block.timestamp > endTime) revert ClaimingEnded();
        
        // Ensure arrays have same length
        if (recipients.length != proofs.length) revert ArrayLengthMismatch();
        
        // Process batch
        _processBatch(phaseId, recipients, proofs, merkleRoot, dropAmount);
    }
    
    /**
     * @notice Helper function to process batch to reduce stack variables
     * @param phaseId The phase ID to process
     * @param recipients Array of recipient addresses
     * @param proofs Array of merkle proofs
     * @param merkleRoot The merkle root for verification
     * @param dropAmount The amount per claim
     */
    function _processBatch(
        uint8 phaseId,
        address[] calldata recipients,
        bytes32[][] calldata proofs,
        bytes32 merkleRoot,
        uint64 dropAmount
    ) private {
        // Check contract balance
        uint256 requiredBalance = uint256(dropAmount) * recipients.length;
        if (IERC20(token).balanceOf(address(this)) < requiredBalance) 
            revert InsufficientBalance();
        
        uint256 successCount;
        uint256 skipCount;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            
            // Skip if null address
            if (recipient == address(0)) {
                unchecked { skipCount++; }
                continue;
            }
            
            // Skip if already claimed
            if (addressClaimed[phaseId][recipient] != 0) {
                unchecked { skipCount++; }
                continue;
            }
            
            // Verify the merkle proof
            bytes32 node = keccak256(abi.encodePacked(recipient));
            bool isValid = MerkleProof.verify(proofs[i], merkleRoot, node);
            
            if (!isValid) {
                unchecked { skipCount++; }
                continue;
            }
            
            // Process valid claim
            _processValidClaim(phaseId, recipient, dropAmount);
            unchecked { successCount++; }
        }
        
        emit BatchProcessed(successCount, skipCount, phaseId);
    }
    
    /**
     * @notice Helper function to process a valid claim in batch processing
     * @param phaseId The phase ID to claim from
     * @param recipient The address receiving tokens
     * @param dropAmount The amount to send
     */
    function _processValidClaim(uint8 phaseId, address recipient, uint64 dropAmount) private {
        // Mark as claimed
        addressClaimed[phaseId][recipient] = 1;
        
        // Update counters
        unchecked {
            phases[phaseId].recipientCount++;
            totalRecipients++;
            totalClaimed += dropAmount;
        }
        
        // Transfer tokens
        IERC20(token).safeTransfer(recipient, dropAmount);
        
        emit Claimed(recipient, dropAmount, phaseId);
    }
    
    /**
     * @notice Checks if an address has already claimed tokens for a specific phase
     * @param phaseId The phase ID to check
     * @param user Address to check
     * @return Whether the address has claimed for the phase
     */
    function isClaimedForPhase(uint8 phaseId, address user) external view returns (bool) {
        if (phaseId >= phases.length) return false;
        return addressClaimed[phaseId][user] != 0;
    }
    
    /**
     * @notice Returns information about a phase's claiming status
     * @param phaseId The phase ID to check
     * @return isActive Whether claiming is currently active
     * @return remainingTime Time until claiming ends (0 if already ended)
     * @return claimAmount Drop amount for the phase
     */
    function phaseStatus(uint8 phaseId) external view returns (bool isActive, uint256 remainingTime, uint256 claimAmount) {
        if (phaseId >= phases.length) return (false, 0, 0);
        
        Phase storage phase = phases[phaseId];
        isActive = phase.active && block.timestamp <= phase.endTime && !paused();
        
        if (block.timestamp < phase.endTime) {
            remainingTime = phase.endTime - block.timestamp;
        } else {
            remainingTime = 0;
        }
        
        claimAmount = phase.dropAmount;
    }
    
    /**
     * @notice Returns the number of phases
     */
    function getPhaseCount() external view returns (uint256) {
        return phases.length;
    }
    
    /**
     * @notice Returns the remaining tokens in the contract
     */
    function remainingTokens() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /* ========== ADMIN FUNCTIONS ========== */
    
    /**
     * @notice Creates a new phase with new merkle root, drop amount, and end time
     * @param merkleRoot Merkle root for the new phase
     * @param dropAmount Amount per claim for the new phase
     * @param endTime End time for the new phase
     * @param setActive Whether to automatically set the new phase as active
     * @return phaseId The ID of the newly created phase
     */
    function createPhase(
        bytes32 merkleRoot,
        uint256 dropAmount,
        uint256 endTime,
        bool setActive
    ) external onlyOwner returns (uint8 phaseId) {
        if (dropAmount == 0) revert ZeroAmount();
        if (endTime <= block.timestamp) revert("End time must be in future");
        if (dropAmount > type(uint64).max) revert("Drop amount too large");
        if (phases.length >= 255) revert("Max phases reached");
        
        phaseId = uint8(phases.length);
        
        phases.push(Phase({
            merkleRoot: merkleRoot,
            dropAmount: uint64(dropAmount),
            endTime: uint64(endTime),
            recipientCount: 0,
            phaseIndex: uint64(phaseId),
            active: setActive
        }));
        
        emit PhaseCreated(phaseId, merkleRoot, dropAmount, endTime);
        
        if (setActive) {
            currentPhaseId = phaseId;
            emit PhaseActivated(phaseId);
        }
        
        return phaseId;
    }
    
    /**
     * @notice Updates an existing phase
     * @param phaseId ID of the phase to update
     * @param merkleRoot New merkle root (use bytes32(0) to keep current)
     * @param dropAmount New drop amount (use 0 to keep current)
     * @param endTime New end time (use 0 to keep current)
     */
    function updatePhase(
        uint8 phaseId,
        bytes32 merkleRoot,
        uint256 dropAmount,
        uint256 endTime
    ) external onlyOwner {
        if (phaseId >= phases.length) revert InvalidPhase();
        
        Phase storage phase = phases[phaseId];
        
        // Update merkle root if provided
        if (merkleRoot != bytes32(0)) {
            phase.merkleRoot = merkleRoot;
        }
        
        // Update drop amount if provided 
        if (dropAmount > 0) {
            if (dropAmount > type(uint64).max) revert("Drop amount too large");
            phase.dropAmount = uint64(dropAmount);
        }
        
        // Update end time if provided
        if (endTime > 0) {
            if (endTime <= block.timestamp) revert("End time must be in future");
            phase.endTime = uint64(endTime);
        }
        
        emit PhaseUpdated(phaseId, phase.merkleRoot, phase.dropAmount, phase.endTime);
    }
    
    /**
     * @notice Sets the active phase
     * @param phaseId ID of the phase to set active
     */
    function setActivePhase(uint8 phaseId) external onlyOwner {
        if (phaseId >= phases.length) revert InvalidPhase();
        
        Phase storage phase = phases[phaseId];
        if (block.timestamp > phase.endTime) revert ClaimingEnded();
        
        currentPhaseId = phaseId;
        phase.active = true;
        
        emit PhaseActivated(phaseId);
    }
    
    /**
     * @notice Deactivates a phase
     * @param phaseId ID of the phase to deactivate
     */
    function deactivatePhase(uint8 phaseId) external onlyOwner {
        if (phaseId >= phases.length) revert InvalidPhase();
        
        phases[phaseId].active = false;
        emit PhaseDeactivated(phaseId);
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
     * @notice Emergency withdrawal of tokens
     * @param tokenAddress Token address to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount to withdraw
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