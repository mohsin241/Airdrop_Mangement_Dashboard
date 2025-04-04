const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const { ethers } = require("ethers");
require("dotenv").config();

module.exports = buildModule("DeployModule", (m) => {
  // Retrieve the private key from the environment
  const privateKey = process.env.privatekey;

  // Derive the address from the private key
  const wallet = new ethers.Wallet(privateKey);
  const initialOwner = wallet.address;

  // Deploy the AirdropToken contract
  const airdropToken = m.contract("AirdropToken", [initialOwner]);

  // Get Merkle root parameter from environment variables
  const merkleRoot = m.getParameter("merkleRoot", process.env.root);

  // Define the drop amount (e.g., 100 tokens with 18 decimals)
  const dropAmount = m.getParameter("dropAmount", 100n * 10n ** 18n);

  const claimStart = m.getParameter("claimStart", 100)

  const claimEnd = m.getParameter("claimEnd",1000)

  // Deploy the MerkleDistributor contract and pass the address of AirdropToken
  const merkleDistributor = m.contract("MerkleDistributor", [
    airdropToken, // Pass the AirdropToken contract instance (its address will be resolved automatically)
    merkleRoot,   // Pass the Merkle root
    dropAmount,
    claimStart,   // Pass the drop amount
    claimEnd,
    initialOwner
  ]);

  // Optionally, interact with the first contract (e.g., mint tokens to the MerkleDistributor)
  const mintAmount = m.getParameter("mintAmount", 1000000n * 10n ** 18n);
  m.call(airdropToken, "mint", [merkleDistributor, mintAmount]);

  // Return both contract instances
  return { airdropToken, merkleDistributor };
});