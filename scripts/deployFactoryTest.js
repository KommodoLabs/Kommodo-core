const { ethers } = require("hardhat");
const bn = require('bignumber.js')  

const { abi: FACTORY_ABI, bytecode: FACTORY_BYTECODE } = require(
  '@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json'
);
const { abi: NFPM_ABI, bytecode: NFPM_BYTECODE } = require(
  '@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json'
);
const { abi: MOCKROUTER_ABI, bytecode: MOCKROUTER_BYTECODE } = require(
  '../artifacts/contracts/test/Router.sol/Router.json'
);
const { abi: WETH9_ABI, bytecode: WETH9_BYTECODE } = require(
  '../test/WETH9.json'
);

const { abi: Factory_KOMMODO_ABI, bytecode: Factory_KOMMODO_BYTECODE } = require(
  '../artifacts/contracts/KommodoFactory.sol/KommodoFactory.json'
);

const { abi: NFLM_ABI, bytecode: NFLM_BYTECODE } = require(
  '../artifacts/contracts/NonfungibleLendManager.sol/NonfungibleLendManager.json'
);

bn.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })
function encodePriceSqrt(reserve1, reserve0){
  return ethers.BigNumber.from(
      new bn(reserve1.toString())
          .div(reserve0.toString())
          .sqrt()
          .multipliedBy(new bn(2).pow(96))
          .integerValue(3)
          .toString()
  )
}

async function main() {
  const [owner] = await ethers.getSigners()
  
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Uniswap V3 with account:", deployer.address);

  // Deploy uniswap Factory
  const Factory = new ethers.ContractFactory(FACTORY_ABI, FACTORY_BYTECODE, deployer);
  const factory = await Factory.deploy();
  await factory.deployed();
  console.log("Factory deployed at:", factory.address);

  // Deploy WETH
  const WETH = new ethers.ContractFactory(WETH9_ABI, WETH9_BYTECODE, deployer);
  const weth = await WETH.deploy();
  await weth.deployed();
  console.log("WETH deployed at:", weth.address);

  // Deploy uniswap NonfungiblePositionManager
  const NFPM = new ethers.ContractFactory(NFPM_ABI, NFPM_BYTECODE, deployer);
  const nfpm = await NFPM.deploy(factory.address, weth.address, ethers.constants.AddressZero);
  await nfpm.deployed();
  console.log("NonfungiblePositionManager deployed at:", nfpm.address);

  // Deploy WETH2
  const WETH2 = new ethers.ContractFactory(WETH9_ABI, WETH9_BYTECODE, deployer);
  const weth2 = await WETH2.deploy();
  await weth2.deployed();
  console.log("WETH2 deployed at:", weth2.address);

  // Deploy uniswap Pool 
  const token0 = weth.address < weth2.address ? weth.address : weth2.address
  const token1 = weth.address < weth2.address ? weth2.address : weth.address
  const fee = 500
  await nfpm.createAndInitializePoolIfNecessary(token0, token1, fee, encodePriceSqrt(1,1), {gasLimit: 5000000})
  const pool = await factory.getPool(token0, token1, fee);
  console.log("uni Pool deployed at:", pool);


  // Deploy uniswap mockrouter
  const MOCKROUTER = new ethers.ContractFactory(MOCKROUTER_ABI, MOCKROUTER_BYTECODE, deployer);
  const mockrouter = await MOCKROUTER.deploy();
  await mockrouter.deployed();
  await mockrouter.initialize(pool, token0, token1);
  console.log("Mockrouter deployed at:", mockrouter.address);


  // Deploy Kommodo Factory
  const Factory_Kommodo = new ethers.ContractFactory(Factory_KOMMODO_ABI, Factory_KOMMODO_BYTECODE, deployer);
  const factoryKommodo = await Factory_Kommodo.deploy(factory.address, 5);
  await factoryKommodo.deployed();
  console.log("Factory Kommodo deployed at:", factoryKommodo.address);

  // Deploy Kommodo pool
  await factoryKommodo.createKommodo(token0, token1, fee, {gasLimit: 5000000})
  const poolKommodo = await factoryKommodo.kommodo(token0, token1, fee);
  console.log("kommodo Pool deployed at:", poolKommodo);

  // Deploy kommodo NonfungibleLenderManager 
  const NFLM = new ethers.ContractFactory(NFLM_ABI, NFLM_BYTECODE, deployer);
  const nflm = await NFLM.deploy(factoryKommodo.address);
  console.log("NonfungibleLendManager deployed at:", nflm.address);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
