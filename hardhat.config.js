require("@nomicfoundation/hardhat-toolbox");
require("hardhat-gas-reporter")
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks:{
    sepolia:{
      accounts:[process.env.privatekey],
      url:process.env.rpc
    }
  },
  gasReporter: {
    enabled: true,
    currency: 'INR',
    gasPrice: 30, // in gwei (set this based on network)
    coinmarketcap: 'f919547f-8e2d-4836-bd60-20cc7af46d81', // optional but useful
    token: 'POL' // or 'BNB' depending on your network
  },
  etherscan:{
    apiKey:{
      sepolia: process.env.etherscan
    }
  }
};
