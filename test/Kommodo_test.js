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
    kommodoFactory = await KommodoFactory.deploy(factory.address, 5, 1)
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
      await kommodo.connect(account2).provide(
        {
          tickLower: ticklower,                           
          amountA: deposit,                   
          amountB: 0                                  
        }
      )
      //Check position
      positionKey = utils.solidityKeccak256(["address", "int24", "int24"], [kommodo.address, ticklower, tickupper])
      AMM_position = await pool.positions(positionKey)
      kommodo_position = await kommodo.assets(ticklower)
      balanceA = await tokenA.balanceOf(account2.address)
      expect(AMM_position.liquidity.toString()).to.not.equal('0')
      expect(AMM_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(amount.minus(deposit).toString()).to.equal(balanceA.toString())
    })
    it('Should take liquidity', async function () {   
      //Burn lending position
      assets = await kommodo.assets(ticklower)
      liquidity = Math.floor((assets.liquidity - assets.locked) / 2)
      withdraw = deposit / 2 - 1
      await kommodo.connect(account2).take(
        {
          tickLower: ticklower,
          liquidity: liquidity,
          amountMinA: 0,
          amountMinB: 0 
          }
      )
      //Check position
      positionKey = utils.solidityKeccak256(["address", "int24", "int24"], [kommodo.address, ticklower, tickupper])
      AMM_position = await pool.positions(positionKey)
      kommodo_position = await kommodo.assets(ticklower)
      kommodo_withdraws = await kommodo.withdraws(ticklower, account2.address)
      expect(AMM_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(AMM_position.tokensOwed0.toString()).to.equal("0")
      expect(withdraw.toString()).to.equal(kommodo_withdraws.amountA)
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
      assets = await kommodo.assets(ticklower)
      liquidity = assets.liquidity - assets.locked
      interest = 1
      expect(assets.feeGrowth1X128).to.equal("0")
      await kommodo.connect(account1).open({
        tickBor: ticklower, 
        liquidityBor: liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colA: 0, 
        colB: 10000, 
        interest: interest
      })
      //Checks
      expect(await tokenA.balanceOf(account1.address)).to.equal(balance0Before.add("49"))
      expect(await weth.balanceOf(account1.address)).to.equal(balance1Before.sub("10006"))
      totalLiquidity = await kommodo.assets(ticklower)
      fee = await kommodo.getFee(10000)
      uint128max = BigNumber.from("340282366920938463463374607431768211455") 
      feegrowth = fee.mul(uint128max).div(assets.liquidity)
      expect(totalLiquidity.locked).to.equal(liquidity.toString())
      expect(totalLiquidity.feeGrowth0X128).to.equal("0")
      expect(totalLiquidity.feeGrowth1X128).to.equal(feegrowth)
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      loan = await kommodo.borrower(borrowKey)
      expect(loan.tokenA).to.equal(false)
      expect(loan.liquidityBor).to.equal("100130")
      expect(loan.interest).to.equal(interest)
      expect(loan.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)
    })
    it('Should [partial]close loan', async function () {           
      //Check after borrow balance      
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("49").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("10006").toString())
      //Close borrow position using connector 
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      pre_loan = await kommodo.borrower(borrowKey)
      await kommodo.connect(account1).close({
        token0: false,
        owner: account1.address,
        tickBor: ticklower,  
        liquidityBor: pre_loan.liquidityBor.div(2), 
        amountCol: 0, 
        interest: 0
      })  
      //Checks   
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("24").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("10006").toString()) 
      post_loan = await kommodo.borrower(borrowKey)
      expect(post_loan.liquidityBor).to.equal(pre_loan.liquidityBor.div(2))
      expect(post_loan.interest).to.equal(pre_loan.interest)
      expect(post_loan.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)     
    })  
    it('Should [full]close loan', async function () {
      //Close borrow position using connector
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      borrower_before = await kommodo.borrower(borrowKey)
      total_liquidity_before = await kommodo.assets(ticklower)
      await kommodo.connect(account1).close({
        token0: false,
        owner: account1.address,
        tickBor: ticklower, 
        liquidityBor: borrower_before.liquidityBor, 
        amountCol: borrower_before.amountCol, 
        interest: borrower_before.interest
      })
      //Checks
      assets = await kommodo.assets(ticklower)
      borrower_after = await kommodo.borrower(borrowKey)
      available_liquidity = assets.liquidity - assets.locked
      total_liquidity_after = await kommodo.assets(ticklower)
      //Difference in tokenA balance is fee (1)
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.minus("1").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("6").toString()) 
      expect(borrower_after.liquidityBor).to.equal("0")
      expect(borrower_after.interest).to.equal("0")
      expect(borrower_after.start).to.equal("0")      
      expect(available_liquidity).to.equal(total_liquidity_after.liquidity)
      expect(total_liquidity_after.liquidity).to.equal(total_liquidity_before.liquidity)
    }) 
    it('Should provide correct interest', async function () {
      assets = await kommodo.assets(ticklower)
      liquidity = assets.liquidity - assets.locked
      interest = 1
      amount = 10000
      await kommodo.connect(account1).open({
        tickBor: ticklower, 
        liquidityBor: liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colA: 0, 
        colB: amount, 
        interest: interest
      })
      //Check unix end time for interest
      current = (await ethers.provider.getBlock('latest')).timestamp
      end = await kommodo.getLoanEnd(account1.address, ticklower, false)
      fee = await kommodo.interest()
      expected = interest / (fee * amount / 10**6) * 31536000
      expect(end - current).to.equal(expected)
      //Check interest calculation from end time
      cost = await kommodo.getInterest(amount, current, end)
      expect(cost).to.equal(interest)
    }) 
    it('Should store feegrowth lender', async function () {
      lenderBefore = await kommodo.lender(ticklower, account2.address)
      expect(lenderBefore.feeGrowth0X128).to.equal("0")
      expect(lenderBefore.feeGrowth1X128).to.equal("0")
      balance0Before = await tokenA.balanceOf(account2.address)
      balance1Before = await weth.balanceOf(account2.address)
      await kommodo.connect(account2).withdraw(ticklower)
      assets = await kommodo.assets(ticklower)
      lenderAfter = await kommodo.lender(ticklower, account2.address)
      expect(assets.feeGrowth0X128).to.equal("0")
      expect(assets.feeGrowth1X128).to.equal(lenderAfter.feeGrowth1X128)
      balance0After = await tokenA.balanceOf(account2.address)
      balance1After = await weth.balanceOf(account2.address)
      balanceChange = balance1After.sub(balance1Before)
      delta = lenderAfter.feeGrowth1X128.sub(lenderBefore.feeGrowth1X128)
      uint128max = BigNumber.from("340282366920938463463374607431768211455") 
      expectedChange = delta.mul(lenderBefore.liquidity).div(uint128max)
      expect(balanceChange).to.equal(expectedChange)
    })
    it('Should change feegrowth after swap', async function () {
      //Deploy mock router
      MockRouter = await ethers.getContractFactory('Router', account1)
      mockRouter = await MockRouter.deploy()
      //Get data
      amount = base.pow("18").multipliedBy("3")
      slot0 = await pool.slot0()
      spacing = await pool.tickSpacing()
      //mint funds
      await tokenA.connect(account2).mint(amount.multipliedBy(2).toString())
      await weth.connect(account2).deposit({value: amount.multipliedBy(2).toString()})
      await tokenA.connect(account2).approve(kommodo.address, amount.multipliedBy(2).toString())
		  await weth.connect(account2).approve(kommodo.address, amount.multipliedBy(2).toString())
      await tokenA.connect(account2).transfer(mockRouter.address, amount.toString())
      await weth.connect(account2).transfer(mockRouter.address, amount.toString())
      //Set swap specific data
      let tokenAdress0
      let tokenAdress1
      let sqrtPrice
      let zeroOne
      if(tokenA.address < weth.address) {
        tokenAdress0 = tokenA.address;
        tokenAdress1 = weth.address
        sqrtPrice = "1461446703485210103287273052203988822378723970341"
        zeroOne = false
        await kommodo.connect(account2).provide({
          tickLower: slot0.tick + spacing * 2,                           
          amountA: amount.div("2").toString(),                   
          amountB: amount.div("2").toString()                                  
        })
      } else {
        tokenAdress0 = weth.address;
        tokenAdress1 = tokenA.address
        sqrtPrice = "4295128740"
        zeroOne = true
        await kommodo.connect(account2).provide({
          tickLower: slot0.tick - spacing * 2,                           
          amountA: amount.div("2").toString(),                   
          amountB: amount.div("2").toString()                                  
        })
      }
      feegrowth0Before = await pool.feeGrowthGlobal0X128()
      feegrowth1Before = await pool.feeGrowthGlobal1X128()
      //call swap from router
      await mockRouter.connect(account2).initialize(pool.address, tokenAdress0, tokenAdress1) 
      await mockRouter.connect(account2).swap(mockRouter.address, zeroOne, "1000000000000000000", sqrtPrice, "0x")
      //Check feegrowth pool
      feegrowth0After = await pool.feeGrowthGlobal0X128()
      feegrowth1After = await pool.feeGrowthGlobal1X128()
      expect(feegrowth0Before).to.equal("0")
      expect(feegrowth1Before).to.equal("0")
      expect(feegrowth0After).to.equal("0")
      expect(feegrowth1After).to.equal("56640052124031978139063049784856")
      //Check feegrowth position kommodo and payout kommodo
      tickUsed = zeroOne ? slot0.tick - spacing * 2 : slot0.tick + spacing * 2
      tickUsedUp = zeroOne ? slot0.tick - spacing : slot0.tick + spacing * 3
      key = ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp])
      positionBefore = await pool.positions(ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp]))
      withdrawsBefore = await kommodo.withdraws(tickUsed, account2.address)
      await kommodo.connect(account2).provide({
                tickLower: tickUsed,                           
                amountA: amount.div("2").toString(),                   
                amountB: amount.div("2").toString()                                  
      })
      positionAfter = await pool.positions(ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp]))
      withdrawsAfter = await kommodo.withdraws(tickUsed, account2.address)
      expect(positionBefore.feeGrowthInside0LastX128).to.equal("0")
      expect(positionBefore.feeGrowthInside1LastX128).to.equal("0")
      expect(positionAfter.feeGrowthInside0LastX128).to.equal("0")
      expect(positionAfter.feeGrowthInside1LastX128).to.equal("56640052124031978139063049784856")
      expect(withdrawsBefore.amountA).to.equal("0")
      expect(withdrawsBefore.amountB).to.equal("0")
      expect(withdrawsAfter.amountA).to.equal("0")
      expect(withdrawsAfter.amountB).to.equal("499999999999998")
    })
    it('Should change withdraw token lender after swap passing tick', async function () {
      //Set swap specific data
      let tokenAdress0
      let tokenAdress1
      let tick = spacing * 3
      if(tokenA.address < weth.address) {
        tokenAdress0 = tokenA.address;
        tokenAdress1 = weth.address
      } else {
        tokenAdress0 = weth.address;
        tokenAdress1 = tokenA.address
      }
      //Deposit kommodo above swap tick - notice deposit amountA
      await kommodo.connect(account2).provide({
        tickLower: tick,                           
        amountA: amount.div("8").toString(),                   
        amountB: "0"                                  
      })
      liquidity = (await kommodo.lender(tick, account2.address)).liquidity
      //Swap to increase above lend tick
      await mockRouter.connect(account2).swap(mockRouter.address, false, "2000000000000000000", "1461446703485210103287273052203988822378723970341", "0x")
      //Close lend position
      withdrawsBefore = await kommodo.withdraws(tick, account2.address)
      await kommodo.connect(account2).take({
          tickLower: tick,
          liquidity: liquidity,
          amountMinA: 0,
          amountMinB: 0 
      }) 
      withdrawsAfter = await kommodo.withdraws(tick, account2.address)
      //Check withdraw after swap - notice deposit assetA and withdraw after swap assetB
      expect(withdrawsBefore.amountA).to.equal("0")
      expect(withdrawsBefore.amountB).to.equal("0")
      expect(withdrawsAfter.amountA).to.equal("0")
      expect(withdrawsAfter.amountB).to.not.equal("0")
    })
  })
  describe("Kommodo_test_unhappy_update", function () {         
    //Provide()
    it('Should fail provide for zero amountA and amountB', async function () {
      //Fail provide() zero amount -> fails in connector call pool.mint(), zero liquidity
      await expect(kommodo.connect(account2).provide(
        {
          tickLower: ticklower,                           
          amountA: 0,                   
          amountB: 0                                  
        })).to.be.reverted
    })
    it('Should fail provide if pool does not exist', async function () {
      //Deploy kommodo for non existing AMM pool
      await kommodoFactory.connect(account1).createKommodo(
        "0x0000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000002",
        500,
        {gasLimit: 5000000}
      )
      let KommodoNAMM = await kommodoFactory.kommodo("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002")
      kommodoNAMM = new Contract(KommodoNAMM, artifacts.Kommodo.abi, provider)
      //Check kommodo exists and no AMM pool exists
      expect(KommodoNAMM).to.not.equal("0x0000000000000000000000000000000000000000")
      expect(await factory.getPool("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002", 500)).to.equal("0x0000000000000000000000000000000000000000") 
      //Fail provide() no AMM pool -> fails in connector call pool.slot0(), no deployed contract
      await expect(kommodoNAMM.connect(account2).provide(
        {
          tickLower: ticklower,                           
          amountA: 100,                   
          amountB: 0                                  
        })).to.be.reverted
    }) 
    it('Should fail provide if ticklower >= tickmax', async function () {
      //AMM set max tick rounded per 10 because of spacing
      MAX_TICK = 887272 - 2
      //Fail provide() ticklower >= tickmax -> fails in connector call TickMath.getSqrtRatioAtTick(tickUpper), above tickmax 
      await expect(kommodo.connect(account2).provide(
        {
          tickLower: MAX_TICK,                           
          amountA: 100,                   
          amountB: 0                               
        })).to.be.reverted
    }) 

/* 
    it('Should fail provide for insufficient funds', async function () {
      //Get total balance and add 1
      let amountA = (await tokenA.balanceOf(account2.address)).add("1")
      await tokenA.connect(account2).approve(kommodo.address, amount.toString())
      //Fail provide() insufficient funds -> fails in connector call TransferHelper.safeTransferFrom, error STF
      await expect(kommodo.connect(account2).provide(
        {
          tickLower: ticklower,                           
          amountA: amountA,                   
          amountB: 0                                  
        })).to.be.revertedWith("STF")
    }) 
    it('Should fail take not the owner', async function () {
      //add further unhappy tests   
    }) 
*/
  }) 
})