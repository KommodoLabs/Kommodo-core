
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
    KommodoFactory: require("../artifacts/contracts/KommodoFactory.sol/KommodoFactory.json"),
    Kommodo: require("../artifacts/contracts/Kommodo.sol/Kommodo.json"),
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
      //console.log('nonfungibleTokenPositionDescriptor', nonfungibleTokenPositionDescriptor.address)
    NonfungiblePositionManager = new ContractFactory(artifacts.NonfungiblePositionManager.abi, artifacts.NonfungiblePositionManager.bytecode, owner)
    nonfungiblePositionManager = await NonfungiblePositionManager.deploy(factory.address, weth.address, nonfungibleTokenPositionDescriptor.address)
      //console.log('nonfungiblePositionManager', nonfungiblePositionManager.address)
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
    //Deploy mock router
    MockRouter = await ethers.getContractFactory('Router', owner)
    mockRouter = await MockRouter.deploy()
      //console.log('mockRouter', mockRouter.address)
    //Deploy kommodo factory
    KommodoFactory = new ContractFactory(artifacts.KommodoFactory.abi, artifacts.KommodoFactory.bytecode, owner)
    kommodoFactory = await KommodoFactory.deploy(nonfungiblePositionManager.address, 500, 10, 1, 10)
      //console.log('kommodoFactory', kommodoFactory.address)
    //Deploy kommodo
    let tokenAdress0
    let tokenAdress1
    if(tokenA.address < weth.address) {a
      tokenAdress0 = tokenA.address;
      tokenAdress1 = weth.address
    } else {
      tokenAdress0 = weth.address;
      tokenAdress1 = tokenA.address
    }
    await kommodoFactory.connect(owner).createKommodo(
      tokenAdress0,
      tokenAdress1,
      {gasLimit: 5000000}
    )
    const kommodoAddress = await kommodoFactory.connect(owner).kommodo(
      tokenAdress0,
      tokenAdress1
    )
    kommodo = new Contract(
        kommodoAddress,
        artifacts.Kommodo.abi,
        provider
    )
      //console.log('kommodo', kommodo.address)
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
      //Check stored global position data 
      let liquidity = await kommodo.connect(signer2).liquidity(tickLower)
      expect(liquidity.liquidityId).to.equal(1)
      expect(liquidity.liquidity).to.not.equal(0)
      expect(liquidity.shares).to.not.equal(0)
      expect(liquidity.locked).to.equal(0)
      expect(liquidity.shares).to.equal(liquidity.liquidity)
      //Check stored individual position share
      expect(await kommodo.connect(signer2).lender(tickLower, signer2.address)).to.equal(liquidity.liquidity)
    })   
    it('Should take liquidity from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get take() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      let share = (await kommodo.connect(signer2).lender(tickLower, signer2.address)).div(2)
      //Check withdraw amounts zero before take
      let withdraw = await kommodo.connect(signer2).withdraws(tickLower, signer2.address)      
      expect(withdraw.amountA).to.equal(0)
      expect(withdraw.amountB).to.equal(0)
      expect(withdraw.timestamp).to.equal(0)
      //Call take
      await kommodo.connect(signer2).take(tickLower, signer2.address, share, 0, 0, { gasLimit: '1000000' })
      //Check stored global position data 
      let liquidity = await kommodo.connect(signer2).liquidity(tickLower)
      expect(liquidity.liquidityId).to.equal(1)
      expect(liquidity.liquidity).to.equal(share.toString())
      expect(liquidity.shares).to.equal(share.toString())
      //Check new user share
      expect(await kommodo.connect(signer2).lender(tickLower, signer2.address)).to.equal(share.toString())
      //Check stored withdraw
      withdraw = await kommodo.connect(signer2).withdraws(tickLower, signer2.address)      
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
      withdraw = await kommodo.connect(signer2).withdraws(tickLower, signer2.address)
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
      //Check start balance 
      expect(await tokenA.balanceOf(owner.address)).to.equal(amount.toString())
      expect(await weth.balanceOf(owner.address)).to.equal(amount.toString())
      //Call borrow
      liquidity_ = 10000000000
      await kommodo.connect(owner).open(
        tickLower,                          //tick lower borrow
        slot0.tick + spacing,               //tick lower collateral
        liquidity_,                         //liquidity borrow
        0,                                  //min amountA borrow
        0,                                  //min amountB borrow
        5003502,                            //amountA collateral
        0,                                  //amountB collateral
        liquidity_ / 1000 + 10              //interest deduction/deposit
      )
      //Check after borrow balance
      expect(await tokenA.balanceOf(owner.address)).to.equal((amount.plus("4991005")).toString())
      expect(await weth.balanceOf(owner.address)).to.equal((amount.minus("5003502")).toString())
      //Check locked 
      liquidity = await kommodo.liquidity(tickLower)
      expect(liquidity.locked).to.equal("9989999990")
      //Check collateral stored
      collateral = await kommodo.collateral(slot0.tick + spacing)
      expect(collateral.collateralId).to.equal("2")
      expect(collateral.amount).to.equal("10015012305")
      //Check borrow stored
      borrower = await kommodo.borrower(slot0.tick + spacing, owner.address)     
      expect(borrower.tick).to.equal(tickLower)
      expect(borrower.liquidity).to.equal("10000000000")
      expect(borrower.liquidityCol).to.equal(collateral.amount)
      expect(borrower.interest).to.equal("10000010")
      expect(borrower.start).to.not.equal(0)
    })    
    it('Should close borrow from pool', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get amount
      let base = new bn(10)
      let amount = base.pow("18")
      //Get close() required data
      let slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      let tickLower = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      //Approve borrowed amount
      await tokenA.connect(owner).approve(kommodo.address, "4996002")
      //Check after borrow balance
      expect(await tokenA.balanceOf(owner.address)).to.equal((amount.plus("4991005")).toString())
      expect(await weth.balanceOf(owner.address)).to.equal((amount.minus("5003502")).toString())
      //Call close
      await kommodo.connect(owner).close(slot0.tick + spacing, owner.address)
      //Check return balance (some interest payed) and minus 1 for rounding LP
      expect(await tokenA.balanceOf(owner.address)).to.equal((amount.minus("4997")).toString())
      expect(await weth.balanceOf(owner.address)).to.equal((amount.minus("1")).toString())
      //Check locked 
      liquidity = await kommodo.liquidity(tickLower)
      expect(liquidity.locked).to.equal(0)
      //Check collateral stored
      collateral = await kommodo.collateral(slot0.tick + spacing)
      expect(collateral.collateralId).to.equal("2")
      expect(collateral.amount).to.equal(0)
      //Check borrow stored
      borrower = await kommodo.borrower(slot0.tick + spacing, owner.address)
      expect(borrower.tick).to.equal(0)
      expect(borrower.liquidity).to.equal(0)
      expect(borrower.liquidityCol).to.equal(0)
      expect(borrower.interest).to.equal(0)
      expect(borrower.start).to.equal(0)
    })
    it('Kommodo tests after swaps', async function () {
      const [owner, signer2] = await ethers.getSigners();
      //Get amount
      let base = new bn(10)
      let amount = base.pow("18").multipliedBy("3")
      //Get data provide
      sqrtPrice = encodePriceSqrt(1,2)
      slot0 = await pool.slot0()
      let spacing = await pool.tickSpacing()
      //deposit liquidity @slot0.tick
      await tokenA.connect(signer2).mint(amount.toString())
      await weth.connect(signer2).deposit({value: amount.toString()})
      await tokenA.connect(signer2).approve(kommodo.address, amount.toString())
		  await weth.connect(signer2).approve(kommodo.address, amount.toString())
      await kommodo.connect(signer2).provide(slot0.tick - spacing * 2, amount.div("3").toString(), amount.div("3").toString(), { gasLimit: '1000000' })
      //check before price and tick
      tick = await pool.connect(signer2).ticks(slot0.tick - spacing * 2)
        //console.log(slot0)
        //console.log(tick)
      //deposit funds for swap in tick
      await tokenA.connect(signer2).transfer(mockRouter.address, amount.div("3").toString())
      await weth.connect(signer2).transfer(mockRouter.address, amount.div("3").toString())
      //initialize mock router
      let tokenAdress0
      let tokenAdress1
      if(tokenA.address < weth.address) {a
        tokenAdress0 = tokenA.address;
        tokenAdress1 = weth.address
      } else {
        tokenAdress0 = weth.address;
        tokenAdress1 = tokenA.address
      }
      await mockRouter.connect(signer2).initialize(pool.address, tokenAdress0, tokenAdress1)
      //call swap from router
      await mockRouter.connect(signer2).swap(signer2.address, true, 100000000000, sqrtPrice, "0x")
      position = await nonfungiblePositionManager.positions(1)
        //console.log(position)
      //Update positions
      await kommodo.connect(signer2).provide(-20, amount.div("3").toString(), amount.div("3").toString(), { gasLimit: '1000000' })
      //Check position update
      position = await nonfungiblePositionManager.positions(1)
        //console.log(position)
      //check new price and tick
      slot0 = await pool.slot0()
      tick = await pool.connect(signer2).ticks(slot0.tick - spacing * 2)
        //console.log(slot0)  
        //console.log(tick)
    })
  }) 
})


