require("@nomiclabs/hardhat-waffle");
require('hardhat-contract-sizer');
require("@nomicfoundation/hardhat-verify");

require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,
        details: { yul: false},
      } 
    }
  },
  
  networks: {
    sepolia: {
      chainId: 11155111,
      url: process.env.SEPOLIA_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
  },

  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY
    }
  },
  sourcify: {
    enabled: true
  }
};
