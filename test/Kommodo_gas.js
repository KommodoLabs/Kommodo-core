
const {Contract, ContractFactory, utils, BigNumber} = require('ethers')
const { expect } = require("chai");
const bn = require('bignumber.js')
const artifacts = {
    UniswapV3Factory: require("@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json"),
    SwapRouter: require("@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json"),
    NFTDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json"),
    NonfungibleTokenPositionDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json"),
    NonfungiblePositionManager: require("@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
    WETH9: require("./WETH9.json"),
    KommodoFactory: require("../artifacts/contracts/KommodoFactory.sol/KommodoFactory.json"),
    Kommodo: require("../artifacts/contracts/Kommodo.sol/Kommodo.json"),
    NonfungibleLendManager: require("../artifacts/contracts/NonfungibleLendManager.sol/NonfungibleLendManager.json"),
};
const UniswapV3Pool = require("@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json")
const { nearestUsableTick } = require('@uniswap/v3-sdk')

const linkLibraries = ({ bytecode, linkReferences }, libraries) => {
  Object.keys(linkReferences).forEach((fileName) => {
    Object.keys(linkReferences[fileName]).forEach((contractName) => {
      if (!libraries.hasOwnProperty(contractName)) {
        throw new Error(`Missing link library name ${contractName}`)
      }
      const address = utils
        .getAddress(libraries[contractName])
        .toLowerCase()
        .slice(2)
      linkReferences[fileName][contractName].forEach(
        ({ start, length }) => {
          const start2 = 2 + start * 2
          const length2 = length * 2
          bytecode = bytecode
            .slice(0, start2)
            .concat(address)
            .concat(bytecode.slice(start2 + length2, bytecode.length))
        }
      )
    })
  })
  return bytecode
}

bn.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })
function encodePriceSqrt(reserve1, reserve0){
  return BigNumber.from(
      new bn(reserve1.toString())
          .div(reserve0.toString())
          .sqrt()
          .multipliedBy(new bn(2).pow(96))
          .integerValue(3)
          .toString()
  )
}

describe("Kommodo_gas", function () {
  const provider  = waffle.provider;
  before(async() => {
    const [owner, signer2] = await ethers.getSigners()
    //Deploy Tokens
    Weth = new ContractFactory(artifacts.WETH9.abi, artifacts.WETH9.bytecode, owner)
    weth = await Weth.deploy()
      //console.log('weth', weth.address)
    Tokens = await ethers.getContractFactory('Token', owner)
    tokenA = await Tokens.deploy()
      //console.log('tokenA', tokenA.address)
    //Deploy Uniswap v3
    Factory = new ContractFactory(artifacts.UniswapV3Factory.abi, artifacts.UniswapV3Factory.bytecode, owner)
    factory = await Factory.deploy()
      //console.log('factory', factory.address)
    SwapRouter = new ContractFactory(artifacts.SwapRouter.abi, artifacts.SwapRouter.bytecode, owner)
    swapRouter = await SwapRouter.deploy(factory.address, weth.address)
      //console.log('swapRouter', swapRouter.address)
    NFTDescriptor = new ContractFactory(artifacts.NFTDescriptor.abi, artifacts.NFTDescriptor.bytecode, owner)
    nftDescriptor = await NFTDescriptor.deploy()
      //console.log('nftDescriptor', nftDescriptor.address)
    const linkedBytecode = linkLibraries(
        {
            bytecode: artifacts.NonfungibleTokenPositionDescriptor.bytecode,
            linkReferences: {
                "NFTDescriptor.sol": {
                    NFTDescriptor: [
                        {
                            length: 20,
                            start: 1681,
                        },
                    ],
                },
            },
        },
        {
            NFTDescriptor: nftDescriptor.address,
        }
    )
    NonfungibleTokenPositionDescriptor = new ContractFactory(artifacts.NonfungibleTokenPositionDescriptor.abi, linkedBytecode, owner)
    nonfungibleTokenPositionDescriptor = await NonfungibleTokenPositionDescriptor.deploy(weth.address, '0x4554480000000000000000000000000000000000000000000000000000000000')
      //console.log('nonfungibleTokenPositionDescriptor', nonfungibleTokenPositionDescriptor.address)
    NonfungiblePositionManager = new ContractFactory(artifacts.NonfungiblePositionManager.abi, artifacts.NonfungiblePositionManager.bytecode, owner)
    nonfungiblePositionManager = await NonfungiblePositionManager.deploy(factory.address, weth.address, nonfungibleTokenPositionDescriptor.address)
      //console.log('nonfungiblePositionManager', nonfungiblePositionManager.address)      
    const sqrtPrice = encodePriceSqrt(1,1)
    let tokenAdress0
    let tokenAdress1
    if(tokenA.address < weth.address) {
      tokenAdress0 = tokenA.address
      tokenAdress1 = weth.address
    } else {
      tokenAdress0 = weth.address
      tokenAdress1 = tokenA.address
    } 
    await nonfungiblePositionManager.connect(owner).createAndInitializePoolIfNecessary(
        tokenAdress0,
        tokenAdress1,
        500,
        sqrtPrice,
        {gasLimit: 5000000}
    )
    const poolAddress = await factory.connect(owner).getPool(
        weth.address,
        tokenA.address,
        500,
    )
    pool = new Contract(
        poolAddress,
        UniswapV3Pool.abi,
        provider
    )
    //Deploy mock router
    MockRouter = await ethers.getContractFactory('Router', owner)
    mockRouter = await MockRouter.deploy()
      //console.log('mockRouter', mockRouter.address)      
    //Deploy kommodofactory
    KommodoFactory = new ContractFactory(artifacts.KommodoFactory.abi, artifacts.KommodoFactory.bytecode, owner)
    kommodoFactory = await KommodoFactory.deploy(factory.address, 5)
      //console.log('kommodoFactory', kommodoFactory.address)
    //Deploy kommodo
    await kommodoFactory.connect(owner).createKommodo(
      tokenAdress0,
      tokenAdress1,
      500,
      {gasLimit: 5000000}
    )
    const kommodoAddress = await kommodoFactory.connect(owner).kommodo(
      tokenAdress0,
      tokenAdress1,
      500
    )
    kommodo = new Contract(
        kommodoAddress,
        artifacts.Kommodo.abi,
        provider
    )
      //console.log('kommodo', kommodo.address)
    //Deploy nonfungibleLendManager 
    NonfungibleLendManager = new ContractFactory(artifacts.NonfungibleLendManager.abi, artifacts.NonfungibleLendManager.bytecode, owner)
    nonfungibleLendManager = await NonfungibleLendManager.deploy(kommodoFactory.address)
      //console.log('nonfungibleLendManager', nonfungibleLendManager.address)
	})
  describe("Kommodo_gas", function () {
    it('Kommodo gas analyses', async function () {          
      const [owner, signer2] = await ethers.getSigners()
      let base = new bn(10)
      let amount = base.pow("18")
      let deposit = 100
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) + 2 * spacing
      //Create estimate
      sqrtPrice = encodePriceSqrt(1,1)
      tokenB = await Tokens.deploy()
      if(tokenA.address < weth.address) {a
        tokenAdress0 = tokenB.address;
        tokenAdress1 = weth.address
      } else {
        tokenAdress0 = weth.address;
        tokenAdress1 = tokenB.address
      }
      await nonfungiblePositionManager.connect(owner).createAndInitializePoolIfNecessary(
          tokenAdress0,
          tokenAdress1,
          500,
          sqrtPrice,
          {gasLimit: 5000000}
      )
      gasCreate = await kommodoFactory.connect(owner).estimateGas.createKommodo(tokenAdress0, tokenAdress1, 500, {gasLimit: 5000000})
      console.log("Create: ", gasCreate.toString());
      //Provide estimates
      await tokenA.connect(signer2).mint(amount.toString())
      await weth.connect(signer2).deposit({value: amount.toString()})
      await tokenA.connect(signer2).approve(kommodo.address, amount.toString())
		  await weth.connect(signer2).approve(kommodo.address, amount.toString())
      gasProvide = await kommodo.connect(signer2).estimateGas.provide(
        {
          tickLower: tickLower,  
          liquidity: 10,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit,
          sender: signer2.address
        }, 
        { gasLimit: '1000000' })
      console.log("Povide mint AMM: ", gasProvide.toString());
      await kommodo.connect(signer2).provide(
        {
          tickLower: tickLower, 
          liquidity: 10,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit,
          sender: signer2.address
        }, 
        { gasLimit: '1000000' })
      gasProvide = await kommodo.connect(signer2).estimateGas.provide(
        {
          tickLower: tickLower,                           
          liquidity: 10,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit,
          sender: signer2.address                               
        },
        { gasLimit: '1000000' })
      console.log("Povide add AMM: ", gasProvide.toString());          
      //Take estimate
      let liquidity = (await kommodo.connect(signer2).lender(tickLower, signer2.address)).liquidity.div(2)
      gasTake = await kommodo.connect(signer2).estimateGas.take(
        {
        tickLower: tickLower,
        liquidity: liquidity,
        amountMinA: 0,
        amountMinB: 0 
        },
        { gasLimit: '1000000' })
      console.log("Take: ", gasTake.toString());         
      //Withdraw estimate
      await kommodo.connect(signer2).take(
        {
          tickLower: tickLower,
          liquidity: liquidity,
          amountMinA: 0,
          amountMinB: 0 
          },
        { gasLimit: '1000000' })
      gasWithdraw = await kommodo.connect(signer2).estimateGas.withdraw(tickLower, signer2.address, 100, 100)
      console.log("Withdraw: ", gasWithdraw.toString()); 
      //Borrow estimate
      await tokenA.connect(owner).mint(amount.toString())
      await weth.connect(owner).deposit({value: amount.toString()})
      await tokenA.connect(owner).approve(kommodo.address, amount.toString())
		  await weth.connect(owner).approve(kommodo.address, amount.toString()) 
      assets = await kommodo.assets(tickLower)
      liquidityBor = assets.liquidity - assets.locked
      tickCol = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      start = (await ethers.provider.getBlock('latest')).timestamp
      interest = await kommodo.getInterest(liquidityBor, start, start + 60) + 10 //mimimum interest deposit of 1 + 10 for rounding
      gasBorrow = await kommodo.connect(owner).estimateGas.open({
        token0: false,                                //collateral tokenA
        tickBor: tickLower,                           //tick lower borrow
        liquidityBor: liquidityBor,                   //liquidity borrow
        borAMin: 0,                                   //min amountA borrow
        borBMin: 0,                                   //min amountB borrow
        colAmount: 10000,                             //amount collateral
        interest: interest                            //interest deposit
      })
      console.log("Borrow mint AMM: ", gasBorrow.toString());    
      await kommodo.connect(owner).open({
        token0: false,                                //collateral tokenA
        tickBor: tickLower,                           //tick lower borrow
        liquidityBor: liquidityBor,                   //liquidity borrow
        borAMin: 0,                                   //min amountA borrow
        borBMin: 0,                                   //min amountB borrow
        colAmount: 10000,                             //amount collateral
        interest: interest                            //interest deposit  
      })
      key = await kommodo.getKey(owner.address, tickLower, false)
      borrower_before = await kommodo.borrower(key)

      await kommodo.connect(owner).close({
        token0: false,                                //collateral tokenA
        owner:  owner.address,                        //owner loan
        tickBor: tickLower,                           //tick lower borrow
        borAMax: 1000000000,                          //max amountA return
        borBMax: 1000000000,                          //max amountB return
      })
      gasBorrow = await kommodo.connect(owner).estimateGas.open({
        token0: false,                                //collateral tokenA
        tickBor: tickLower,                           //tick lower borrow
        liquidityBor: liquidityBor,                   //liquidity borrow
        borAMin: 0,                                   //min amountA borrow
        borBMin: 0,                                   //min amountB borrow
        colAmount: 10000,                             //amount collateral
        interest: interest                            //interest deposit  
      })
      console.log("Borrow add AMM: ", gasBorrow.toString())   
      await kommodo.connect(owner).open({
        token0: false,                                //collateral tokenA
        tickBor: tickLower,                           //tick lower borrow
        liquidityBor: liquidityBor,                   //liquidity borrow
        borAMin: 0,                                   //min amountA borrow
        borBMin: 0,                                   //min amountB borrow
        colAmount: 10000,                             //amount collateral
        interest: interest                            //interest deposit  
      })
      //Interest adjust estimate
      gasSetInterest = await kommodo.connect(owner).estimateGas.setInterest(
        false,                                        //tokenA as collateral
        tickLower,                                    //tick lower borrow
        -1                                            //interest delta 
      )
      console.log("SetInterest: ", gasSetInterest.toString())
      //Partial Close estimate
      gasPartialClose = await kommodo.connect(owner).estimateGas.adjust({
        token0: false,                                //tokenA as collateral
        tickBor: tickLower,                           //tick lower borrow
        liquidityBor: 1,                              //liquidity borrow
        borAMax: 10000000,                            //max amountA return
        borBMax: 10000000,                            //max amountB return
        amountCol: 0,                                 //amount collateral
        interest: interest                            //new interest amount 
      })
      console.log("[Partial]Close: ", gasPartialClose.toString())
      //Full close estimate
      gasFullClose = await kommodo.connect(owner).estimateGas.close({
        token0: false,                                //collateral tokenA
        owner:  owner.address,                        //owner loan
        tickBor: tickLower,                           //tick lower borrow
        borAMax: 1000000000,                          //max amountA return
        borBMax: 1000000000,                          //max amountB return
      })
      console.log("[Full]Close: ", gasFullClose.toString())
      //Approve NFT estimate
      await tokenA.connect(signer2).approve(nonfungibleLendManager.address, amount.toString())
		  await weth.connect(signer2).approve(nonfungibleLendManager.address, amount.toString())   
      gasApproveNFT = await nonfungibleLendManager.connect(signer2).estimateGas.poolApprove(
          weth.address,
          tokenA.address,
          500
      )
      console.log("Approve NFT: ", gasApproveNFT.toString());
      await nonfungibleLendManager.connect(signer2).poolApprove(
          weth.address,
          tokenA.address,
          500
      )
      //Provide NFT estimates
      gasMintNFT = await nonfungibleLendManager.connect(signer2).estimateGas.mint(
        {
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: tickLower + 2*spacing,  
          liquidity: 1,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit                                 
        }
      )
      console.log("Mint mint AMM NFT: ", gasMintNFT.toString());
      await nonfungibleLendManager.connect(signer2).mint(
        {
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: tickLower + 2*spacing,                           
          liquidity: 1,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit                                  
        }
      )
      gasMintNFT = await nonfungibleLendManager.connect(signer2).estimateGas.mint(
        {
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: tickLower + 2*spacing,                           
          liquidity: 1,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit                                   
        }
      )
      console.log("Mint mint add AMM NFT: ", gasMintNFT.toString());
      gasProvideNFT = await nonfungibleLendManager.connect(signer2).estimateGas.provide(
        {
          tokenId: 1,
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: tickLower + 2*spacing,                           
          liquidity: 1,                         
          amountMaxA: deposit,                   
          amountMaxB: deposit                                    
        }
      )
      console.log("Povide AMM NFT: ", gasProvideNFT.toString());
      let liq_nft = (await nonfungibleLendManager.connect(signer2).position(1)).liquidity
      gasTakeNFT = await nonfungibleLendManager.connect(signer2).estimateGas.take(
        {
          tokenId: 1,
          liquidity: liq_nft.toString(),                         
          amountMinA: 0,                   
          amountMinB: 0,
          recipient: signer2.address                                 
        }
      )
      console.log("take AMM NFT: ", gasTakeNFT.toString());
      await nonfungibleLendManager.connect(signer2).take(
        {
          tokenId: 1,
          liquidity: liq_nft.toString(),                         
          amountMinA: 0,                   
          amountMinB: 0,
          recipient: signer2.address                                       
        }
      )
      gasWithdrawNFT = await nonfungibleLendManager.connect(signer2).estimateGas.withdraw(
        {
          tokenId: 1,                   
          amountA: deposit,                   
          amountB: deposit,    
          recipient: signer2.address                             
        }
      )
      console.log("withdraw AMM NFT: ", gasWithdrawNFT.toString());
      await nonfungibleLendManager.connect(signer2).withdraw(
        {
          tokenId: 1,                   
          amountA: deposit,                   
          amountB: deposit,    
          recipient: signer2.address                             
        }
      )
      gasBurnwNFT = await nonfungibleLendManager.connect(signer2).estimateGas.burn(1)
      console.log("burn AMM NFT: ", gasBurnwNFT.toString());
    })
  })
})


