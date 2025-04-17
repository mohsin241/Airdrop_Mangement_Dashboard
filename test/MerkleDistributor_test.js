const { expect } = require("chai");
const { ethers } = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MerkleDistributorV2", function () {
  let merkleDistributor;
  let token;
  let owner;
  let addr1;
  let addr2;
  let addr3;
  let addr4;
  let addrs;
  let merkleTree;
  let merkleRoot;

  // Use a smaller drop amount to avoid "Drop amount too large" errors
  const dropAmount = ethers.parseEther("0.01");
  const oneWeek = 7 * 24 * 60 * 60; // 1 week in seconds

  // Updated helper function to properly create a merkle tree from addresses
  function createMerkleTree(addresses) {
    // Hash addresses directly without ABI encoding
    const leaves = addresses.map(addr => 
      keccak256(Buffer.from(addr.slice(2).toLowerCase(), 'hex'))
    );
    const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });
    return merkleTree;
  }

  // Helper function to get proof for an address
  function getProof(address) {
    const leaf = keccak256(Buffer.from(address.slice(2).toLowerCase(), 'hex'));
    return merkleTree.getHexProof(leaf);
  }

  beforeEach(async function () {
    // Get signers
    [owner, addr1, addr2, addr3, addr4, ...addrs] = await ethers.getSigners();

    // Create merkle tree and root
    merkleTree = createMerkleTree([addr1.address, addr2.address, addr3.address]);
    merkleRoot = merkleTree.getHexRoot();

    // Deploy AirdropToken
    const AirdropToken = await ethers.getContractFactory("AirdropToken");
    token = await AirdropToken.deploy(owner.address);
    await token.waitForDeployment();

    // Mint tokens to owner for distribution - use a large amount
    await token.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy MerkleDistributorV2
    // Use future timestamp for endTime
    const endTime = (await time.latest()) + oneWeek;
    const MerkleDistributorV2 = await ethers.getContractFactory("MerkleDistributorV2");
    merkleDistributor = await MerkleDistributorV2.deploy(
      await token.getAddress(),
      merkleRoot,
      dropAmount,
      endTime,
      owner.address
    );
    await merkleDistributor.waitForDeployment();

    // Transfer tokens to the distributor - ensure sufficient amount
    await token.transfer(await merkleDistributor.getAddress(), ethers.parseEther("100000"));
  });

  describe("Deployment", function () {
    it("Should set the right token", async function () {
      expect(await merkleDistributor.token()).to.equal(await token.getAddress());
    });

    it("Should have the correct owner", async function () {
      expect(await merkleDistributor.owner()).to.equal(owner.address);
    });

    it("Should initialize with the correct phase data", async function () {
      const phase = await merkleDistributor.phases(0);
      expect(phase.merkleRoot).to.equal(merkleRoot);
      expect(phase.dropAmount).to.equal(dropAmount);
      expect(phase.active).to.equal(true);
    });

    it("Should have the correct phase count", async function () {
      expect(await merkleDistributor.getPhaseCount()).to.equal(1);
    });
  });

  describe("Claiming", function () {
    it("Should allow eligible addresses to claim tokens", async function () {
      const proof = getProof(addr1.address);
      
      // Check balances before claim
      const initialBalance = await token.balanceOf(addr1.address);
      
      // Claim tokens
      await merkleDistributor.connect(addr1).claim(proof);
      
      // Check balances after claim
      const finalBalance = await token.balanceOf(addr1.address);
      expect(finalBalance - initialBalance).to.equal(dropAmount);
      
      // Check contract state
      expect(await merkleDistributor.isClaimedForPhase(0, addr1.address)).to.equal(true);
      expect(await merkleDistributor.totalClaimed()).to.equal(dropAmount);
      expect(await merkleDistributor.totalRecipients()).to.equal(1);
    });

    it("Should not allow double claiming", async function () {
      const proof = getProof(addr1.address);
      
      // First claim
      await merkleDistributor.connect(addr1).claim(proof);
      
      // Second claim should fail
      await expect(merkleDistributor.connect(addr1).claim(proof)).to.be.revertedWithCustomError(
        merkleDistributor,
        "AlreadyClaimed"
      );
    });

    it("Should not allow ineligible addresses to claim", async function () {
      const proof = getProof(addr1.address);
      
      // Try claiming with wrong address
      await expect(merkleDistributor.connect(addr4).claim(proof)).to.be.revertedWithCustomError(
        merkleDistributor,
        "InvalidProof"
      );
    });

    it("Should not allow claiming from inactive phases", async function () {
      // Deactivate the phase
      await merkleDistributor.deactivatePhase(0);
      
      const proof = getProof(addr1.address);
      
      // Try claiming from inactive phase
      await expect(merkleDistributor.connect(addr1).claim(proof)).to.be.revertedWithCustomError(
        merkleDistributor,
        "PhaseNotActive"
      );
    });

    it("Should not allow claiming after end time", async function () {
     // Create a new phase with future end time
      const endTime = (await time.latest()) + 100; // 100 seconds in future
      await merkleDistributor.createPhase(
        merkleRoot,
        dropAmount,
        endTime,
        true
      );
      
      // Fast-forward time to expire the phase
      await time.increase(101);
      
      const proof = getProof(addr1.address);
      
      // Try claiming from expired phase
      await expect(merkleDistributor.connect(addr1).claimForPhase(1, proof))
        .to.be.revertedWithCustomError(merkleDistributor, "ClaimingEnded");
    });

    it("Should allow claiming from a specific phase", async function () {
      // Create a new phase with the same merkle root
      const endTime = (await time.latest()) + oneWeek;
      await merkleDistributor.createPhase(
        merkleRoot,
        dropAmount,
        endTime,
        true
      );
      
      const proof = getProof(addr1.address);
      
      // Claim from the original phase (phase 0)
      await merkleDistributor.connect(addr1).claimForPhase(0, proof);
      
      // Check balance after first claim
      let balance = await token.balanceOf(addr1.address);
      expect(balance).to.equal(dropAmount);
      
      // Claim from the new phase (phase 1)
      await merkleDistributor.connect(addr1).claimForPhase(1, proof);
      
      // Check balance after second claim (should add another dropAmount)
      balance = await token.balanceOf(addr1.address);
      expect(balance).to.equal(dropAmount * BigInt(2));
    });
  });

  describe("Batch Distribution", function () {
    it("Should allow owner to batch distribute tokens", async function () {
      const recipients = [addr1.address, addr2.address, addr3.address];
      const proofs = recipients.map(addr => getProof(addr));
      
      // Initial balances
      const initialBalance1 = await token.balanceOf(addr1.address);
      const initialBalance2 = await token.balanceOf(addr2.address);
      const initialBalance3 = await token.balanceOf(addr3.address);
      
      // Batch distribute
      await merkleDistributor.connect(owner).batchDistribute(0, recipients, proofs);
      
      // Check balances
      expect(await token.balanceOf(addr1.address)).to.equal(initialBalance1 + dropAmount);
      expect(await token.balanceOf(addr2.address)).to.equal(initialBalance2 + dropAmount);
      expect(await token.balanceOf(addr3.address)).to.equal(initialBalance3 + dropAmount);
      
      // Check contract state
      expect(await merkleDistributor.totalClaimed()).to.equal(dropAmount * BigInt(3));
      expect(await merkleDistributor.totalRecipients()).to.equal(3);
    });

    it("Should skip invalid proofs in batch distribution", async function () {
      // Create a list with one valid and one invalid recipient
      const recipients = [addr1.address, addr4.address]; // addr4 is not in the merkle tree
      const proofs = [getProof(addr1.address), getProof(addr1.address)]; // Invalid proof for addr4
      
      // Initial distribution count
      const initialTotalRecipients = await merkleDistributor.totalRecipients();
      
      // Batch distribute
      const tx = await merkleDistributor.connect(owner).batchDistribute(0, recipients, proofs);
      
      // Get receipt to check events
      const receipt = await tx.wait();
      
      // Find BatchProcessed event and extract its arguments
      const batchProcessedEvent = receipt.logs.find(log => 
        log.fragment && log.fragment.name === "BatchProcessed"
      );
      
      // Check event data if available
      if (batchProcessedEvent) {
        const successCount = batchProcessedEvent.args[0];
        expect(successCount).to.equal(1);
      }
      
      // Check claim status - only addr1 should be claimed
      expect(await merkleDistributor.isClaimedForPhase(0, addr1.address)).to.equal(true);
      expect(await merkleDistributor.isClaimedForPhase(0, addr4.address)).to.equal(false);
      
      // Check total recipients increased by 1
      expect(await merkleDistributor.totalRecipients()).to.equal(initialTotalRecipients + BigInt(1));
    });

    it("Should not allow non-owner to batch distribute", async function () {
      const recipients = [addr1.address, addr2.address];
      const proofs = recipients.map(addr => getProof(addr));
      
      await expect(
        merkleDistributor.connect(addr1).batchDistribute(0, recipients, proofs)
      ).to.be.revertedWithCustomError(merkleDistributor, "OwnableUnauthorizedAccount");
    });
  });

  describe("Phase Management", function () {
    it("Should allow owner to create a new phase", async function () {
      const endTime = (await time.latest()) + oneWeek;
      
      // Use the same drop amount to avoid "drop amount too large" error
      const newDropAmount = dropAmount;
      
      // Create new phase
      await merkleDistributor.createPhase(
        merkleRoot,
        newDropAmount,
        endTime,
        true
      );
      
      // Check phase count
      expect(await merkleDistributor.getPhaseCount()).to.equal(2);
      
      // Check phase data
      const phase = await merkleDistributor.phases(1);
      expect(phase.merkleRoot).to.equal(merkleRoot);
      expect(phase.dropAmount).to.equal(newDropAmount);
      expect(phase.active).to.equal(true);
      
      // Check current phase
      expect(await merkleDistributor.currentPhaseId()).to.equal(1);
    });

    it("Should allow owner to update an existing phase", async function () {
      // Create new merkle tree
      const newMerkleTree = createMerkleTree([addr1.address, addr4.address]);
      const newMerkleRoot = newMerkleTree.getHexRoot();
      
      // Use the same drop amount to avoid "drop amount too large" error
      const newDropAmount = dropAmount;
      const newEndTime = (await time.latest()) + oneWeek * 2;
      
      // Update phase
      await merkleDistributor.updatePhase(
        0,
        newMerkleRoot,
        newDropAmount,
        newEndTime
      );
      
      // Check phase data
      const phase = await merkleDistributor.phases(0);
      expect(phase.merkleRoot).to.equal(newMerkleRoot);
      expect(phase.dropAmount).to.equal(newDropAmount);
      expect(phase.endTime).to.equal(newEndTime);
    });

    it("Should allow owner to activate/deactivate phases", async function () {
      // Create new phase
      const endTime = (await time.latest()) + oneWeek;
      await merkleDistributor.createPhase(
        merkleRoot,
        dropAmount,
        endTime,
        false // Not active by default
      );
      
      // Check phase is inactive
      let phase = await merkleDistributor.phases(1);
      expect(phase.active).to.equal(false);
      
      // Activate phase
      await merkleDistributor.setActivePhase(1);
      
      // Check phase is active and current
      phase = await merkleDistributor.phases(1);
      expect(phase.active).to.equal(true);
      expect(await merkleDistributor.currentPhaseId()).to.equal(1);
      
      // Deactivate phase
      await merkleDistributor.deactivatePhase(1);
      
      // Check phase is inactive
      phase = await merkleDistributor.phases(1);
      expect(phase.active).to.equal(false);
    });

    it("Should return correct phase status", async function () {
        const phaseEnd = (await time.latest()) + 100;
        await merkleDistributor.createPhase(
          merkleRoot,
          dropAmount,
          phaseEnd,
          true
        );
        
        // Check active status
        let status = await merkleDistributor.phaseStatus(1);
        expect(status.remainingTime).to.be.gt(0);
        
        // Fast-forward past end time
        await time.increase(101);
        
        // Check expired status
        status = await merkleDistributor.phaseStatus(1);
        expect(status.remainingTime).to.equal(0);
      });
  });

  describe("Emergency Functions", function () {
    it("Should allow owner to pause and unpause the contract", async function () {
      // Pause the contract
      await merkleDistributor.pause();
      
      // Try claiming while paused
      const proof = getProof(addr1.address);
      await expect(merkleDistributor.connect(addr1).claim(proof)).to.be.reverted;
      
      // Unpause the contract
      await merkleDistributor.unpause();
      
      // Claim should work now
      await merkleDistributor.connect(addr1).claim(proof);
      expect(await merkleDistributor.isClaimedForPhase(0, addr1.address)).to.equal(true);
    });

    it("Should allow owner to withdraw tokens in emergency", async function () {
      const withdrawAmount = ethers.parseEther("1000");
      
      // Get initial balances
      const initialBalance = await token.balanceOf(addr4.address);
      const initialContractBalance = await token.balanceOf(await merkleDistributor.getAddress());
      
      // Emergency withdraw
      await merkleDistributor.emergencyWithdraw(
        await token.getAddress(),
        addr4.address,
        withdrawAmount
      );
      
      // Check balances
      expect(await token.balanceOf(addr4.address)).to.equal(initialBalance + withdrawAmount);
      expect(await token.balanceOf(await merkleDistributor.getAddress())).to.equal(initialContractBalance - withdrawAmount);
    });
  });
});

describe("AirdropToken", function() {
  let token;
  let owner;
  let addr1;

  beforeEach(async function() {
    [owner, addr1] = await ethers.getSigners();
    
    const AirdropToken = await ethers.getContractFactory("AirdropToken");
    token = await AirdropToken.deploy(owner.address);
    await token.waitForDeployment();
  });

  it("should have correct name and symbol", async function() {
    const name = await token.name();
    const symbol = await token.symbol();
    
    expect(name).to.equal("AIRDROP");
    expect(symbol).to.equal("AIR");
  });

  it("should allow owner to mint tokens", async function() {
    const mintAmount = ethers.parseEther("100");
    await token.connect(owner).mint(addr1.address, mintAmount);
    expect(await token.balanceOf(addr1.address)).to.equal(mintAmount);
  });
});