const hre = require("hardhat");

async function main() {
  const contractAddress = "0x883Ae63cf7c4Fe3F7d74620F44856aae0e8Ec8d9";
  const constructorArgs = [
    "0x0227628f3F023bb0B980b67D528571c95c6DaC1c",
    5
  ];

  const networkChainId = await hre.ethers.provider.getNetwork().then(n => n.chainId);

  await hre.run("verify:verify", {
    address: contractAddress,
    constructorArguments: constructorArgs,
    chainId: networkChainId 
  });
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
