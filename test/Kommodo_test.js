const {Contract, ContractFactory, utils, BigNumber} = require('ethers')
const { expect } = require("chai")
const bn = require('bignumber.js')
const artifacts = {
    UniswapV3Factory: require("@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json"),
    SwapRouter: require("@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json"),
    NFTDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json"),
    NonfungibleTokenPositionDescriptor: require("@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json"),
    NonfungiblePositionManager: require("@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
    WETH9: require("./WETH9.json"),
    Connector: require("../artifacts/contracts/Connector.sol/Connector.json"),
    KommodoFactory: require("../artifacts/contracts/KommodoFactory.sol/KommodoFactory.json"),
    Kommodo: require("../artifacts/contracts/Kommodo.sol/Kommodo.json"),
}
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
  const provider = waffle.provider
  before(async() => {
    const [owner, signer2] = await ethers.getSigners()
    account1 = owner;
    account2 = signer2;
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
    )
    NonfungibleTokenPositionDescriptor = new ContractFactory(artifacts.NonfungibleTokenPositionDescriptor.abi, linkedBytecode, owner)
    nonfungibleTokenPositionDescriptor = await NonfungibleTokenPositionDescriptor.deploy(weth.address)
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
    //Deploy kommodo
    KommodoFactory = new ContractFactory(artifacts.KommodoFactory.abi, artifacts.KommodoFactory.bytecode, owner)
    kommodoFactory = await KommodoFactory.deploy(factory.address, 500, 10, 100, 1, 100)
      //console.log('kommodoFactory', kommodoFactory.address)
    //Deploy kommodo
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
    //load position data
    slot0 = await pool.slot0()
    spacing = await pool.tickSpacing()
    ticklower = nearestUsableTick(slot0.tick, spacing) + 2 * spacing
    tickupper = ticklower + spacing
	})
  describe("Kommodo_test_happy_update", function () {        
    before(async function () {
      //Mint tokens and approve kommodo
      base = new bn(10)
      amount = base.pow("18")
      await tokenA.connect(account2).mint(amount.toString())
      await weth.connect(account2).deposit({value: amount.toString()})
      await tokenA.connect(account2).approve(kommodo.address, amount.toString())
		  await weth.connect(account2).approve(kommodo.address, amount.toString())
      await tokenA.connect(account1).mint(amount.toString())
      await weth.connect(account1).deposit({value: amount.toString()})
      await tokenA.connect(account1).approve(kommodo.address, amount.toString())
		  await weth.connect(account1).approve(kommodo.address, amount.toString())
    });
    //Lender (LP) functions
    it('Should provide liquidity', async function () { 
      //Check kommodo stored correct factory
      expect(await kommodoFactory.factory()).to.equal((factory.address).toString())
      expect(await kommodo.factory()).to.equal((factory.address).toString())
      //Mint lending position
      deposit = 100
      await kommodo.connect(account2).provide(ticklower, deposit, 0)
      //Check position
      positionKey = utils.solidityKeccak256(["address", "int24", "int24"], [kommodo.address, ticklower, tickupper])
      AMM_position = await pool.positions(positionKey)
      kommodo_position = await kommodo.liquidity(ticklower)
      balanceA = await tokenA.balanceOf(account2.address)
      expect(AMM_position.liquidity.toString()).to.not.equal('0')
      expect(AMM_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(amount.minus(deposit).toString()).to.equal(balanceA.toString())
    })
    it('Should take liquidity', async function () {   
      //Burn lending position
      liquidity = Math.floor((await kommodo.availableLiquidity(ticklower + 887272)) / 2)
      withdraw = deposit / 2 - 1
      await kommodo.connect(account2).take(ticklower, account2.address, liquidity, 0, 0)
      //Check position
      positionKey = utils.solidityKeccak256(["address", "int24", "int24"], [kommodo.address, ticklower, tickupper])
      AMM_position = await pool.positions(positionKey)
      kommodo_position = await kommodo.liquidity(ticklower)
      kommodo_withdraws = await kommodo.withdraws(ticklower, account2.address)
      expect(AMM_position.liquidity).to.equal(await kommodo.availableLiquidity(ticklower + 887272))
      expect(AMM_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(AMM_position.tokensOwed0.toString()).to.equal(withdraw.toString())
      expect(AMM_position.tokensOwed0.toString()).to.equal(kommodo_withdraws.amountA)
    })
    it('Should withdraw liquidity', async function () {      
      //Withdraw position
      await kommodo.connect(account2).withdraw(ticklower)
      //Check position
      positionKey = utils.solidityKeccak256(["address", "int24", "int24"], [kommodo.address, ticklower, tickupper])
      position = await pool.positions(positionKey)
      balanceA = await tokenA.balanceOf(account2.address)
      expect(position.tokensOwed0.toString()).to.equal('0') 
      expect(balanceA.toString()).to.equal(amount.minus(deposit).plus(withdraw).toString())
    })
    //Borrower functions 
    it('Should open loan', async function () {
      //Check start balance 
      balance0Before = await tokenA.balanceOf(account1.address)
      balance1Before = await weth.balanceOf(account1.address)
      expect(balance0Before).to.equal(amount.toString())
      expect(balance1Before).to.equal(amount.toString())
      //Open borrow position using connector
      liquidityBor = await kommodo.availableLiquidity(ticklower + 887272)
      start = (await ethers.provider.getBlock('latest')).timestamp
      interest = await kommodo.getInterest(ticklower, slot0.tick - 2 * spacing, liquidity, start, start + 60)
      fee = await kommodo.getFee(liquidity)
      tickCol = nearestUsableTick(slot0.tick, spacing) - 2 * spacing
      await kommodo.connect(account1).open({
        tickLowerBor: ticklower, 
        tickLowerCol: tickCol, 
        liquidityBor: liquidityBor, 
        borAMin: 0,
        borBMin: 0, 
        colA: 0, 
        colB: 100, 
        interest: interest
      })
      //Checks
      expect(await tokenA.balanceOf(account1.address)).to.equal(balance0Before.add("49"))
      expect(await weth.balanceOf(account1.address)).to.equal(balance1Before.sub("100"))
      totalLiquidity = await kommodo.liquidity(ticklower)
      expect(totalLiquidity.locked).to.equal(liquidity.toString())
      collateral = await kommodo.collateral(tickCol)
      expect(collateral).to.equal("200160")   
      borrowKey = await kommodo.getKey(account1.address, ticklower, tickCol)
      borrower = await kommodo.borrower(borrowKey)
      expect(borrower.liquidityBor).to.equal("100130")
      expect(borrower.liquidityCol).to.equal("200160")
      expect(borrower.interest).to.equal(interest)
      expect(borrower.fee).to.equal(fee)
      expect(borrower.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)
    })
    it('Should [partial]close loan', async function () {           
      //Check after borrow balance      
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("49").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("100").toString())
      //Close borrow position using connector  
      pre_borrower = await kommodo.borrower(borrowKey)
      await kommodo.connect(account1).close({
        tickLowerBor: ticklower, 
        tickLowerCol: tickCol, 
        liquidityBor: pre_borrower.liquidityBor.div(2), 
        liquidityCol: 0, 
        interest: 0,
        owner: account1.address
      })  
      //Checks   
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("24").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("100").toString()) 
      post_borrower = await kommodo.borrower(borrowKey)
      expect(post_borrower.liquidityBor).to.equal(pre_borrower.liquidityBor.div(2))
      expect(post_borrower.liquidityCol).to.equal(pre_borrower.liquidityCol)
      expect(post_borrower.interest).to.equal(pre_borrower.interest)
      expect(post_borrower.fee).to.equal(pre_borrower.fee)
      expect(post_borrower.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)
    })
    it('Should [full]close loan', async function () {
      //Close borrow position using connector
      borrowKey = await kommodo.getKey(account1.address, ticklower, tickCol)
      borrower_before = await kommodo.borrower(borrowKey)
      total_liquidity_before = await kommodo.liquidity(ticklower)
      await kommodo.connect(account1).close({
        tickLowerBor: ticklower, 
        tickLowerCol: tickCol, 
        liquidityBor: borrower_before.liquidityBor, 
        liquidityCol: borrower_before.liquidityCol, 
        interest: borrower_before.interest,
        owner: account1.address
      })
      //Checks
      borrower_after = await kommodo.borrower(borrowKey)
      available_liquidity = await kommodo.availableLiquidity(ticklower + 887272)
      total_liquidity_after = await kommodo.liquidity(ticklower)
      //Difference in tokenA balance is rounding (1) and fee (1) and weth is rounding (1)
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.minus("2").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("1").toString()) 
      expect(borrower_after.liquidityBor).to.equal("0")
      expect(borrower_after.liquidityCol).to.equal("0")
      expect(borrower_after.interest).to.equal("0")
      expect(borrower_after.fee).to.equal("0")
      expect(borrower_after.start).to.equal("0")
      expect(available_liquidity).to.equal(total_liquidity_after.liquidity)
      expect(total_liquidity_after.liquidity).to.equal(total_liquidity_before.liquidity.add(borrower_before.fee))
    }) 
  })
  describe("Kommodo_test_unhappy_update", function () {      
    //Provide()
    it('Should fail provide for zero amountA and amountB', async function () {
      //Fail provide() zero amount -> fails in connector call pool.mint(), zero liquidity
      await expect(kommodo.connect(account2).provide(ticklower, 0, 0)).to.be.reverted
    })
    it('Should fail provide if pool does not exist', async function () {
      //Deploy kommodo for non existing AMM pool
      await kommodoFactory.connect(account1).createKommodo(
        "0x0000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000002",
        {gasLimit: 5000000}
      )
      let KommodoNAMM = await kommodoFactory.kommodo("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002")
      kommodoNAMM = new Contract(KommodoNAMM, artifacts.Kommodo.abi, provider)
      //Check kommodo exists and no AMM pool exists
      expect(KommodoNAMM).to.not.equal("0x0000000000000000000000000000000000000000")
      expect(await factory.getPool("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002", 500)).to.equal("0x0000000000000000000000000000000000000000") 
      //Fail provide() no AMM pool -> fails in connector call pool.slot0(), no deployed contract
      await expect(kommodoNAMM.connect(account2).provide(ticklower, 100, 0)).to.be.reverted
    }) 
    it('Should fail provide if ticklower >= tickmax', async function () {
      //AMM set max tick rounded per 10 because of spacing
      MAX_TICK = 887272 - 2
      //Fail provide() ticklower >= tickmax -> fails in connector call TickMath.getSqrtRatioAtTick(tickUpper), above tickmax 
      await expect(kommodo.connect(account2).provide(MAX_TICK, 100, 0)).to.be.reverted
    }) 
    it('Should fail provide for insufficient funds', async function () {
      //Get total balance and add 1
      let amountA = (await tokenA.balanceOf(account2.address)).add("1")
      await tokenA.connect(account2).approve(kommodo.address, amount.toString())
      //Fail provide() insufficient funds -> fails in connector call TransferHelper.safeTransferFrom, error STF
      await expect(kommodo.connect(account2).provide(ticklower, amountA, 0)).to.be.revertedWith("STF")
    }) 
    it('Should fail take not the owner', async function () {
      //add further unhappy tests
    }) 
  }) 
})