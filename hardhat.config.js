require("@nomiclabs/hardhat-waffle");
require('hardhat-contract-sizer');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 500,
        details: { yul: false},
      } 
    }
  },  
};
