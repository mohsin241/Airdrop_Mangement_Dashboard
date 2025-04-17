const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("AirdropToken", function () {
  let airdropToken;
  let owner;
  let addr1;
  let addr2;

  beforeEach(async function () {
    // Get signers
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy the contract
    const AirdropToken = await ethers.getContractFactory("AirdropToken");
    airdropToken = await AirdropToken.deploy(owner.address);
    await airdropToken.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await airdropToken.owner()).to.equal(owner.address);
    });

    it("Should have correct name and symbol", async function () {
      expect(await airdropToken.name()).to.equal("AIRDROP");
      expect(await airdropToken.symbol()).to.equal("AIR");
    });

    it("Should have 0 initial supply", async function () {
      expect(await airdropToken.totalSupply()).to.equal(0);
    });
  });

  describe("Minting", function () {
    it("Should allow owner to mint tokens", async function () {
      const mintAmount = ethers.parseEther("100");
      await airdropToken.connect(owner).mint(addr1.address, mintAmount);
      
      expect(await airdropToken.totalSupply()).to.equal(mintAmount);
      expect(await airdropToken.balanceOf(addr1.address)).to.equal(mintAmount);
    });

    it("Should fail when non-owner tries to mint tokens", async function () {
      const mintAmount = ethers.parseEther("100");
      
      await expect(
        airdropToken.connect(addr1).mint(addr1.address, mintAmount)
      ).to.be.revertedWithCustomError(airdropToken, "OwnableUnauthorizedAccount");
    });
  });

  describe("Transfers", function () {
    beforeEach(async function () {
      // Mint some tokens to addr1 for testing transfers
      const mintAmount = ethers.parseEther("100");
      await airdropToken.connect(owner).mint(addr1.address, mintAmount);
    });

    it("Should transfer tokens between accounts", async function () {
      const transferAmount = ethers.parseEther("50");
      
      // Transfer from addr1 to addr2
      await airdropToken.connect(addr1).transfer(addr2.address, transferAmount);
      
      // Check balances
      expect(await airdropToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("50"));
      expect(await airdropToken.balanceOf(addr2.address)).to.equal(transferAmount);
    });

    it("Should fail if sender doesn't have enough tokens", async function () {
      const initialBalance = await airdropToken.balanceOf(addr1.address);
      const transferAmount = initialBalance + ethers.parseEther("1"); // More than balance
      
      await expect(
        airdropToken.connect(addr1).transfer(addr2.address, transferAmount)
      ).to.be.reverted;
    });
  });

  describe("Ownership", function () {
    it("Should allow owner to transfer ownership", async function () {
      await airdropToken.connect(owner).transferOwnership(addr1.address);
      expect(await airdropToken.owner()).to.equal(addr1.address);
      
      // Original owner should no longer be able to mint
      const mintAmount = ethers.parseEther("100");
      await expect(
        airdropToken.connect(owner).mint(addr2.address, mintAmount)
      ).to.be.revertedWithCustomError(airdropToken, "OwnableUnauthorizedAccount");
      
      // New owner should be able to mint
      await airdropToken.connect(addr1).mint(addr2.address, mintAmount);
      expect(await airdropToken.balanceOf(addr2.address)).to.equal(mintAmount);
    });
  });
});