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


  // Optionally, interact with the first contract (e.g., mint tokens to the MerkleDistributor)
  const mintAmount = m.getParameter("mintAmount", 100000n * 10n ** 18n);
  m.call(airdropToken, "mint", [initialOwner, mintAmount]);

  // Return both contract instances
  return { airdropToken};
});