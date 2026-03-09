require("dotenv").config();
const { ethers } = require("hardhat");

const { abi: Factory_KOMMODO_ABI, bytecode: Factory_KOMMODO_BYTECODE } = require(
  '../artifacts/contracts/KommodoFactory.sol/KommodoFactory.json'
);

const { abi: NFLM_ABI, bytecode: NFLM_BYTECODE } = require(
  '../artifacts/contracts/NonfungibleLendManager.sol/NonfungibleLendManager.json'
);

async function main() {

  //Input vars
  const sepolia_univ3_factory = "0x0227628f3F023bb0B980b67D528571c95c6DaC1c"
  const multiplier = 5

  const token0 = "0x92855643bA41dBb71a3d9586BB7B31e966D6eFE1"
  const token1 = "0x1F3dC2F36f81b4b43F847E2293b3f2fc0983b7c9"
  const fee = 500

  const provider = new ethers.providers.JsonRpcProvider(
    process.env.SEPOLIA_URL,
    {
      name: "sepolia",
      chainId: 11155111,
    }
  );
  const signer = new ethers.Wallet(
    process.env.PRIVATE_KEY,
    provider
  );
  console.log("Deploying with:", signer.address);

  // Deploy Kommodo Factory
  const Factory_Kommodo = new ethers.ContractFactory(Factory_KOMMODO_ABI, Factory_KOMMODO_BYTECODE, signer);
  const factoryKommodo = await Factory_Kommodo.deploy(sepolia_univ3_factory, multiplier);
  await factoryKommodo.deployed();
  console.log("Factory Kommodo deployed at:", factoryKommodo.address);

  // Deploy kommodo NonfungibleLenderManager 
  const NFLM = new ethers.ContractFactory(NFLM_ABI, NFLM_BYTECODE, signer);
  const nflm = await NFLM.deploy(factoryKommodo.address);
  console.log("NonfungibleLendManager deployed at:", nflm.address);

  // Deploy Kommodo pool
  const txt = await nflm.deploy(token0, token1, fee, {gasLimit: 5000000})
  await txt.wait();
  const poolKommodo = await factoryKommodo.kommodo(token0, token1, fee);
  console.log("kommodo Pool deployed at:", poolKommodo);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
