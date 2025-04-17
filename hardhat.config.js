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
    currency: "inr",
    coinmarketcap: "f919547f-8e2d-4836-bd60-20cc7af46d81",
    gasPriceApi: `https://api.etherscan.io/api?module=proxy&action=eth_gasPrice&apikey=${process.env.etherscan}`
  },
  etherscan:{
    apiKey:{
      sepolia: process.env.etherscan
    }
  }
};
