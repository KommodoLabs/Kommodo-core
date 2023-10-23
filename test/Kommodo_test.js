
const {Contract, ContractFactory, utils, BigNumber} = require('ethers')
const { expect } = require("chai");
const bn = require('bignumber.js')
const artifacts = {
    UniswapV3Factory: require("@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json"),
    SwapRouter: require("@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json"),
    NFTDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json"),
    NonfungibleTokenPositionDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json"),
    NonfungiblePositionManager: require("@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
    WETH9: require("../WETH9.json"),
    Kommodo: require("../artifacts/contracts/Kommodo.sol/Kommodo.json"),
    Positions: require("../artifacts/contracts/Positions.sol/Positions.json")
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

describe("Kommodo_test", function () {
  const provider  = waffle.provider;
  before(async() => {
    const [owner, signer2] = await ethers.getSigners();  
    //Deploy Tokens
    Weth = new ContractFactory(artifacts.WETH9.abi, artifacts.WETH9.bytecode, owner)
    weth = await Weth.deploy()
    console.log('weth', weth.address)
    Tokens = await ethers.getContractFactory('Token', owner)
    tokenA = await Tokens.deploy()
    console.log('tokenA', tokenA.address)
    //Deploy Uniswap v3
    Factory = new ContractFactory(artifacts.UniswapV3Factory.abi, artifacts.UniswapV3Factory.bytecode, owner)
    factory = await Factory.deploy()
    console.log('factory', factory.address)
    SwapRouter = new ContractFactory(artifacts.SwapRouter.abi, artifacts.SwapRouter.bytecode, owner)
    swapRouter = await SwapRouter.deploy(factory.address, weth.address)
    console.log('swapRouter', swapRouter.address)
    NFTDescriptor = new ContractFactory(artifacts.NFTDescriptor.abi, artifacts.NFTDescriptor.bytecode, owner)
    nftDescriptor = await NFTDescriptor.deploy()
    console.log('nftDescriptor', nftDescriptor.address)
    const linkedBytecode = linkLibraries(
        {
            bytecode: artifacts.NonfungibleTokenPositionDescriptor.bytecode,
            linkReferences: {
                "NFTDescriptor.sol": {
                    NFTDescriptor: [
                        {
                            length: 20,
                            start: 1261,
                        },
                    ],
                },
            },
        },
        {
            NFTDescriptor: nftDescriptor.address,
        }
    );
    NonfungibleTokenPositionDescriptor = new ContractFactory(artifacts.NonfungibleTokenPositionDescriptor.abi, linkedBytecode, owner)
    nonfungibleTokenPositionDescriptor = await NonfungibleTokenPositionDescriptor.deploy(weth.address)
    console.log('nonfungibleTokenPositionDescriptor', nonfungibleTokenPositionDescriptor.address)
    NonfungiblePositionManager = new ContractFactory(artifacts.NonfungiblePositionManager.abi, artifacts.NonfungiblePositionManager.bytecode, owner)
    nonfungiblePositionManager = await NonfungiblePositionManager.deploy(factory.address, weth.address, nonfungibleTokenPositionDescriptor.address)
    console.log('nonfungiblePositionManager', nonfungiblePositionManager.address)
    const sqrtPrice = encodePriceSqrt(1,1)
    await nonfungiblePositionManager.connect(owner).createAndInitializePoolIfNecessary(
        weth.address,
        tokenA.address,
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
    //Deploy kommodo
    Kommodo = new ContractFactory(artifacts.Kommodo.abi, artifacts.Kommodo.bytecode, owner)
    kommodo = await Kommodo.deploy()
    console.log('kommodo', kommodo.address)
    //Initialize Kommodo
    let spacing = await pool.tickSpacing()
    let tokenAdress0
    let tokenAdress1
    if(tokenA.address < weth.address) {a
      tokenAdress0 = tokenA.address;
      tokenAdress1 = weth.address
    } else {
      tokenAdress0 = weth.address;
      tokenAdress1 = tokenA.address
    }
    await kommodo.connect(signer2).initialize(nonfungiblePositionManager.address, factory.address, tokenAdress0, tokenAdress1, spacing, 500, 1)
    addressLNFT = await kommodo.connect(signer2).liquidityNFT()
    liquidityNFT = new Contract(
      addressLNFT,
      artifacts.Positions.abi,
      provider
    )
    console.log('liquidityNFT', addressLNFT)
    addressCNFT = await kommodo.connect(signer2).collateralNFT()
    collateralNFT = new Contract(
      addressCNFT,
      artifacts.Positions.abi,
      provider
    )
    console.log('collateralNFT', addressCNFT)
	})
  describe("Kommodo_test", function () {
    it('Should provide liquidity to pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get amount
      let base = new bn(10)
      let amount = base.pow("18")
      //Get provide() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      //Mint funds 
      await tokenA.connect(signer2).mint(amount.toString())
      await weth.connect(signer2).deposit({value: amount.toString()})
      await tokenA.connect(signer2).approve(kommodo.address, amount.toString())
		  await weth.connect(signer2).approve(kommodo.address, amount.toString())
      expect(await tokenA.balanceOf(signer2.address)).to.equal(amount.toString())
      expect(await weth.balanceOf(signer2.address)).to.equal(amount.toString())
      //Call provide()
      await kommodo.connect(signer2).provide(tickLower, amount.toString(), amount.toString(), { gasLimit: '1000000' })
      //Check deposit success
      expect(await tokenA.balanceOf(signer2.address)).to.equal(0)
      expect(await weth.balanceOf(signer2.address)).to.equal(0)
      //Check mint NFT
      expect(await liquidityNFT.balanceOf(signer2.address)).to.equal(1)
      expect(await liquidityNFT.ownerOf(1)).to.equal(signer2.address)
      //Check stored global position data 
      let liquidity = await kommodo.connect(signer2).liquidity(tickLower)
      expect(liquidity.liquidityId).to.equal(1)
      expect(liquidity.liquidity).to.not.equal(0)
      expect(liquidity.shares).to.not.equal(0)
      expect(liquidity.locked).to.equal(0)
      expect(liquidity.shares).to.equal(liquidity.liquidity)
      //Check stored individual position share
      expect(await kommodo.connect(signer2).lender(tickLower, 1)).to.equal(liquidity.liquidity)
    })
    it('Should take liquidity from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get take() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      let share = (await kommodo.connect(signer2).lender(tickLower, 1)).div(2)
      //Check withdraw amounts zero before take
      let withdraw = await kommodo.connect(signer2).withdraws(tickLower,signer2.address)      
      expect(withdraw.amountA).to.equal(0)
      expect(withdraw.amountB).to.equal(0)
      expect(withdraw.timestamp).to.equal(0)
      //Call take
      await kommodo.connect(signer2).take(tickLower, 1, signer2.address, share, 0, 0,{ gasLimit: '1000000' })
      //Check stored global position data 
      let liquidity = await kommodo.connect(signer2).liquidity(tickLower)
      expect(liquidity.liquidityId).to.equal(1)
      expect(liquidity.liquidity).to.equal(share.toString())
      expect(liquidity.shares).to.equal(share.toString())
      //Check new user share
      expect(await kommodo.connect(signer2).lender(tickLower, 1)).to.equal(share.toString())
      //Check stored withdraw
      withdraw = await kommodo.connect(signer2).withdraws(tickLower,signer2.address)      
      if (withdraw.amountA == 0) {
        expect(withdraw.amountB).to.not.equal(0)
      } else {
        expect(withdraw.amountA).to.not.equal(0)
      }
      expect(withdraw.timestamp).to.not.equal(0)
    })
    it('Should withdraw from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();  
      //Get amount
      let base = new bn(10)
      let amount = base.pow("18").div("2").minus("1")
      //Get withdraw() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      //Check withdraw exists
      withdraw = await kommodo.connect(signer2).withdraws(tickLower,signer2.address)
      if (withdraw.amountA == 0) {
        expect(withdraw.amountB).to.not.equal(0)
      } else {
        expect(withdraw.amountA).to.not.equal(0)
      }
      expect(withdraw.timestamp).to.not.equal(0)
      //Check balance zero before
      expect(await tokenA.balanceOf(signer2.address)).to.equal(0)
      expect(await weth.balanceOf(signer2.address)).to.equal(0)
      await kommodo.connect(signer2).withdraw(tickLower)
      //Check withdraw cleared
      withdraw = await kommodo.connect(signer2).withdraws(tickLower,signer2.address)
      expect(withdraw.amountA).to.equal(0)
      expect(withdraw.amountB).to.equal(0)
      expect(withdraw.timestamp).to.equal(0)
      //Check withdraw received
      balanceA = await tokenA.balanceOf(signer2.address)
      balanceB = await weth.balanceOf(signer2.address)
      if (balanceA == 0) {
        expect(balanceB).to.equal(amount.toString())
      } else {
        expect(balanceA).to.equal(amount.toString())
      }
    })
    it('Should borrow from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get amount
      let base = new bn(10)
      let amount = base.pow("18")
      //Get borrow() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      //Mint collateral funds  
      await tokenA.connect(owner).mint(amount.toString())
      await weth.connect(owner).deposit({value: amount.toString()})
      await tokenA.connect(owner).approve(kommodo.address, amount.toString())
		  await weth.connect(owner).approve(kommodo.address, amount.toString())
      
      
      //Starting balance owner
      balance0 = await tokenA.balanceOf(owner.address)
      balance1 = await weth.balanceOf(owner.address)
      console.log("before borrow")
      console.log(balance0.toString())
      console.log(balance1.toString())


      //Call borrow
      await kommodo.connect(owner).open(
        tickLower,                          //tick lower borrow
        slot0.tick + spacing,               //tick lower collateral
        10000000000,                        //liquidity borrow
        0,                                  //min amountA borrow
        0,                                  //min amountB borrow
        5003502,                            //amountA collateral
        0,                                  //amountB collateral
        0                                   //interest deduction/deposit
      )

      //5003502 == minmum deposit collateral (based on the tick used!)
      //4996001 == borrow amount
      
      balance0 = await tokenA.balanceOf(owner.address)
      balance1 = await weth.balanceOf(owner.address)
      console.log("after borrow")
      console.log(balance0.toString())
      console.log(balance1.toString())

      //Check borrow
      collateral = await kommodo.borrower(slot0.tick + spacing, 1)
      //console.log(collateral)


    })
    it('Should close borrow from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()

      //Approve borrowed amount
      await tokenA.connect(owner).approve(kommodo.address, "4996002")


      //Starting balance owner
      balance0 = await tokenA.balanceOf(owner.address)
      balance1 = await weth.balanceOf(owner.address)
      console.log("before close")
      console.log(balance0.toString())
      console.log(balance1.toString())
      
      //Call close
      await kommodo.connect(owner).close(slot0.tick + spacing, 1)

      //End balance owner
      balance0 = await tokenA.balanceOf(owner.address)
      balance1 = await weth.balanceOf(owner.address)
      console.log("after close")
      console.log(balance0.toString())
      console.log(balance1.toString())
    })
  })
  describe("Kommodo_gas", function () {
    it('Kommodo gas analyses', async function () {
      //Provide estimate
      const [owner, signer2] = await ethers.getSigners()
      let base = new bn(10)
      let amount = base.pow("18")
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      await tokenA.connect(signer2).mint(amount.toString())
      await weth.connect(signer2).deposit({value: amount.toString()})
      await tokenA.connect(signer2).approve(kommodo.address, amount.toString())
		  await weth.connect(signer2).approve(kommodo.address, amount.toString())
      gasProvide = await kommodo.connect(signer2).estimateGas.provide(tickLower, amount.toString(), amount.toString(), { gasLimit: '1000000' })
      console.log("Povide: ", gasProvide.toString());
      //Take estimate
      let share = (await kommodo.connect(signer2).lender(tickLower, 1)).div(2)
      let withdraw = await kommodo.connect(signer2).withdraws(tickLower,signer2.address)      
      gasTake = await kommodo.connect(signer2).estimateGas.take(tickLower, 1, signer2.address, share, 0, 0,{ gasLimit: '1000000' })
      console.log("Take: ", gasTake.toString());
      //Withdraw estimate
      await tokenA.connect(signer2).mint(amount.toString())
      await weth.connect(signer2).deposit({value: amount.toString()})
      await tokenA.connect(signer2).approve(kommodo.address, amount.toString())
		  await weth.connect(signer2).approve(kommodo.address, amount.toString())
      await kommodo.connect(signer2).provide(tickLower, amount.toString(), amount.toString(), { gasLimit: '1000000' })
      await kommodo.connect(signer2).take(tickLower, 1, signer2.address, share, 0, 0,{ gasLimit: '1000000' })
      gasWithdraw = await kommodo.connect(signer2).estimateGas.withdraw(tickLower)
      console.log("Withdraw: ", gasWithdraw.toString());
      //Borrow estimate
      await tokenA.connect(owner).mint(amount.toString())
      await weth.connect(owner).deposit({value: amount.toString()})
      await tokenA.connect(owner).approve(kommodo.address, amount.toString())
		  await weth.connect(owner).approve(kommodo.address, amount.toString())
      gasBorrow = await kommodo.connect(owner).estimateGas.open(
        tickLower,                          //tick lower borrow
        slot0.tick + spacing,               //tick lower collateral
        10000000000,                        //liquidity borrow
        0,                                  //min amountA borrow
        0,                                  //min amountB borrow
        5003502,                            //amountA collateral
        0,                                  //amountB collateral
        0                                   //interest deduction/deposit
      )
      console.log("Borrow: ", gasBorrow.toString());
      //Close estimate
      await kommodo.connect(owner).open(
        tickLower,                          //tick lower borrow
        slot0.tick + spacing,               //tick lower collateral
        10000000000,                        //liquidity borrow
        0,                                  //min amountA borrow
        0,                                  //min amountB borrow
        5003502,                            //amountA collateral
        0,                                  //amountB collateral
        0                                   //interest deduction/deposit
      )
      await tokenA.connect(owner).approve(kommodo.address, "4996002")
      gasClose = await kommodo.connect(owner).estimateGas.close(slot0.tick + spacing, 2)
      console.log("Close: ", gasClose.toString());
    })
  })
})


/*
Test implementations:

- PROVIDE()
  x SUCCES PROVIDE
  - FAIL WHEN PROVIDE SHARE == 0
  - SHARE CHANGE AFTER INTEREST DEPOSIT
- TAKE()
  x SUCCESS TAKE() WHEN OWNER
  - FAIL TAKE() WHEN NOT OWNER
  - FAIL TAKE() NO POOL LIQUIDITY
  - FAIL TAKE() INSUFFICIENT USER SHARES
  - FAIL TAKE() INSUFFICIENT USER LIQ
- WITHDRAW()
  x SUCCESS WITHDRAW AFTER DELAY
  - FAIL WITHDRAW BEFORE DELAY
  - FAIL WHEN NO WITHDRAW AVAILABLE
- BORROW()
  - SUCCESS BORROW()
- CLOSE()
  - SUCCESS CLOSE()





TODO:
  - ADD CHECKS TO TESTS BORROW && CLOSE

  - CHANGE INTEREST PAYMENT -> LINEAIR BASED ON DELTA Pc/Pb ==> WITHIN CLOSE() 
  - ADD REQUIRE MINIMUM AMOUNT OF INTEREST (minimum percentage of liquidity + > 0)
  - ADD FACTORY + GASANALYSES DEPLOY NEW POOL

*/




