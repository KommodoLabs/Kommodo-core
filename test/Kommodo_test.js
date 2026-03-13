const { time } = require("@nomicfoundation/hardhat-network-helpers");

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
    NonfungibleLendManager: require("../artifacts/contracts/NonfungibleLendManager.sol/NonfungibleLendManager.json"),
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
    const [owner, signer2, signer3] = await ethers.getSigners()
    account1 = owner;
    account2 = signer2;
    account3 = signer3;
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
    //Deploy kommodo factory
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
    //load position data
    slot0 = await pool.slot0()
    spacing = await pool.tickSpacing()
    ticklower = nearestUsableTick(slot0.tick, spacing) + 2 * spacing
    tickupper = ticklower + spacing
	})


  describe("Kommodo_test_happy", function () {        
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
          liquidity: 200000,                           
          amountMaxA: deposit,                   
          amountMaxB: 0,
          sender: account2.address                                   
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
      balanceA = await tokenA.balanceOf(account2.address)
      expect(AMM_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(AMM_position.tokensOwed0.toString()).to.equal("0")
      expect(kommodo_withdraws.amountA).to.equal(withdraw)
      expect(balanceA.toString()).to.equal(amount.minus(deposit).toString())
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
      interest = 10
      expect(assets.feeGrowth1X128).to.equal("0")
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: ticklower, 
        liquidityBor: liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: 10000, 
        interest: interest
      })
      //Checks
      expect(await tokenA.balanceOf(account1.address)).to.equal(balance0Before.add("49"))
      expect(await weth.balanceOf(account1.address)).to.equal(balance1Before.sub("10015"))
      totalLiquidity = await kommodo.assets(ticklower)
      fee = await kommodo.getFee(10000)
      uint128max = BigNumber.from("340282366920938463463374607431768211455") 
      feegrowth = fee.mul(uint128max).div(assets.liquidity)
      expect(totalLiquidity.locked).to.equal(liquidity.toString())
      expect(totalLiquidity.feeGrowth0X128).to.equal("0")
      expect(totalLiquidity.feeGrowth1X128).to.equal(feegrowth)
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      loan = await kommodo.borrower(borrowKey)
      expect(loan.liquidityBor).to.equal(liquidity)
      expect(loan.interest).to.equal(interest)
      expect(loan.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)
    })
    it('Should increase interest loan', async function () {
      balance0Before = await tokenA.balanceOf(account1.address)
      balance1Before = await weth.balanceOf(account1.address)
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      pre_loan = await kommodo.borrower(borrowKey)
      await kommodo.connect(account1).setInterest(
        false,                                //tokenA as collateral
        ticklower,                            //tick lower borrow
        2                                     //interest delta 
      )
      post_loan = await kommodo.borrower(borrowKey)
      expect(post_loan.interest).to.equal(pre_loan.interest.add("2").sub("1")) //minus 1 roundup used interest
      expect(await tokenA.balanceOf(account1.address)).to.equal(balance0Before)
      expect(await weth.balanceOf(account1.address)).to.equal(balance1Before.sub("2"))
    })
    it('Should decrease interest loan', async function () {
      balance0Before = await tokenA.balanceOf(account1.address)
      balance1Before = await weth.balanceOf(account1.address)
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      pre_loan = await kommodo.borrower(borrowKey)
      await kommodo.connect(account1).setInterest(
        false,                                //tokenA as collateral
        ticklower,                            //tick lower borrow
        -2                                    //interest delta 
      )
      post_loan = await kommodo.borrower(borrowKey)
      expect(post_loan.interest).to.equal(pre_loan.interest.sub("2").sub("1")) //minus 1 roundup used interest
      expect(await tokenA.balanceOf(account1.address)).to.equal(balance0Before)
      expect(await weth.balanceOf(account1.address)).to.equal(balance1Before.add("2"))
    })
    it('Should [partial]close loan', async function () {     
      //Check after borrow balance      
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("49").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("10015").toString())
      //Close borrow position using connector 
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      pre_loan = await kommodo.borrower(borrowKey)
      await kommodo.connect(account1).adjust({
        token0: false,
        tickBor: ticklower,  
        liquidityBor: pre_loan.liquidityBor.div(2), 
        borAMax: BigInt(amount),
        borBMax: BigInt(amount),
        amountCol: 0, 
        interest:  0
      })  
      //Checks   
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.plus("24").toString())
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("10015").toString()) 
      post_loan = await kommodo.borrower(borrowKey)
      expect(post_loan.liquidityBor).to.equal(pre_loan.liquidityBor.div(2))
      const timeStamp = (await ethers.provider.getBlock("latest")).timestamp
      let used = await kommodo.getInterest(post_loan[1], post_loan[3], timeStamp) + 1n 
      expect(post_loan.interest).to.equal(pre_loan.interest - used)
      expect(post_loan.start).to.equal((await ethers.provider.getBlock('latest')).timestamp)  
    })    
    it('Should [full]close loan', async function () {
      //Close borrow position using connector
      borrowKey = await kommodo.getKey(account1.address, ticklower, false)
      borrower_before = await kommodo.borrower(borrowKey)
      total_liquidity_before = await kommodo.assets(ticklower)
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: ticklower,                          
        borAMax:  BigInt(amount),
        borBMax:  BigInt(amount)
      })
      //Checks
      assets = await kommodo.assets(ticklower)
      borrower_after = await kommodo.borrower(borrowKey)
      available_liquidity = assets.liquidity - assets.locked
      total_liquidity_after = await kommodo.assets(ticklower)
      expect(await tokenA.balanceOf(account1.address)).to.equal(amount.minus("1").toString()) //Rounding 
      expect(await weth.balanceOf(account1.address)).to.equal(amount.minus("9").toString()) //Rounding in the before steps + interest paid
      expect(borrower_after.liquidityBor).to.equal("0")
      expect(borrower_after.interest).to.equal("0")
      expect(borrower_after.start).to.equal("0")      
      expect(available_liquidity).to.equal(total_liquidity_after.liquidity)
      expect(total_liquidity_after.liquidity).to.equal(total_liquidity_before.liquidity)
    }) 
    it('Should provide correct interest', async function () {
      assets = await kommodo.assets(ticklower)
      liquidity = assets.liquidity - assets.locked
      interest = 10
      amount = 10000
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: ticklower, 
        liquidityBor: liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: amount, 
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
      //check close other fail
      await expect(kommodo.connect(account2).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: ticklower,                          
        borAMax:  BigInt(amount),
        borBMax:  BigInt(amount)
      })).to.be.revertedWith("close: not authorized")
      //Increase past to half check half interest cost
      delta = (end.sub(current)).div(2)
      await time.increase(ethers.utils.hexlify(delta));
      current = (await ethers.provider.getBlock('latest')).timestamp
      end = await kommodo.getLoanEnd(account1.address, ticklower, false)
      cost = await kommodo.getInterest(amount, current, end)
      expect(BigInt(interest / 2)).to.equal(cost)
      //Withdraw unused interest
      await expect(kommodo.connect(account1).setInterest(false, ticklower, -5)).to.be.revertedWith("panic code 0x11")
      await kommodo.connect(account1).setInterest(false, ticklower, -4)
      borrower_before = await kommodo.borrower(borrowKey)
      expect(borrower_before.interest).to.equal("0")
      //Increase past ending -> close other account
      await time.increase(10);
      await kommodo.connect(account2).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: ticklower,                          
        borAMax:  BigInt(amount),
        borBMax:  BigInt(amount)
      })
      borrower_after = await kommodo.borrower(borrowKey)
      expect(borrower_after.start).to.equal("0")
    }) 
    it('Should store feegrowth lender', async function () {
      lenderBefore = await kommodo.lender(ticklower, account2.address)
      expect(lenderBefore.feeGrowth0X128).to.equal("0")
      expect(lenderBefore.feeGrowth1X128).to.equal("0")
      balance0Before = await tokenA.balanceOf(account2.address)
      balance1Before = await weth.balanceOf(account2.address)
      await kommodo.connect(account2).withdraw(ticklower, account2.address, 100, 100)
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
          liquidity: 20000000000,                           
          amountMaxA: amount.div("2").toString(),                   
          amountMaxB: amount.div("2").toString(),                          
          sender: account2.address                                  
        })
      } else {
        tokenAdress0 = weth.address;
        tokenAdress1 = tokenA.address
        sqrtPrice = "4295128740"
        zeroOne = true
        await kommodo.connect(account2).provide({
          tickLower: slot0.tick - spacing * 2,                           
          liquidity: 20000000000,                           
          amountMaxA: amount.div("2").toString(),                   
          amountMaxB: amount.div("2").toString(),  
          sender: account2.address                                   
        })
      }
      feegrowth0Before = await pool.feeGrowthGlobal0X128()
      feegrowth1Before = await pool.feeGrowthGlobal1X128()
      //call swap from router
      await mockRouter.connect(account2).initialize(pool.address, tokenAdress0, tokenAdress1) 
      await mockRouter.connect(account2).swap(mockRouter.address, zeroOne, "10000000000", sqrtPrice, "0x")
      //Check feegrowth pool
      feegrowth0After = await pool.feeGrowthGlobal0X128()
      feegrowth1After = await pool.feeGrowthGlobal1X128()
      expect(feegrowth0Before).to.equal("0")
      expect(feegrowth1Before).to.equal("0")
      expect(feegrowth0After).to.equal("0")
      expect(feegrowth1After).to.not.equal("0")
      //Check feegrowth position kommodo and payout kommodo
      tickUsed = zeroOne ? slot0.tick - spacing * 2 : slot0.tick + spacing * 2
      tickUsedUp = zeroOne ? slot0.tick - spacing : slot0.tick + spacing * 3
      key = ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp])
      positionBefore = await pool.positions(ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp]))
      withdrawsBefore = await kommodo.withdraws(tickUsed, account2.address)
      await kommodo.connect(account2).provide({
                tickLower: tickUsed,        
                liquidity: 1,                           
                amountMaxA: amount.div("2").toString(),                   
                amountMaxB: amount.div("2").toString(),                     
                sender: account2.address                                   
      })

      positionAfter = await pool.positions(ethers.utils.solidityKeccak256(["address", "uint24", "int24"], [kommodo.address, tickUsed, tickUsedUp]))
      withdrawsAfter = await kommodo.withdraws(tickUsed, account2.address)
      expect(positionBefore.feeGrowthInside0LastX128).to.equal("0")
      expect(positionBefore.feeGrowthInside1LastX128).to.equal("0")
      expect(positionAfter.feeGrowthInside0LastX128).to.equal("0")
      expect(positionAfter.feeGrowthInside1LastX128).to.not.equal("0")
      expect(withdrawsBefore.amountA).to.equal("0")
      expect(withdrawsBefore.amountB).to.equal("0")
      expect(withdrawsAfter.amountA).to.equal("0")
      expect(withdrawsAfter.amountB).to.not.equal("0")
      //return slot0 price
      await mockRouter.connect(account2).swap(mockRouter.address, !zeroOne, "10000000000", "79228162514264337593543950336", "0x")
    })    
    it('Should pay interest lender after swap passing tick', async function () {
      //Set swap specific data
      let tokenAdress0
      let tokenAdress1
      slot0 = await pool.slot0()
      let tick = nearestUsableTick(slot0.tick, spacing) + 3 * spacing
      //let tick = spacing * 3
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
        liquidity: 100000000000,                           
        amountMaxA: amount.div("8").toString(),                   
        amountMaxB: 0,                        
        sender: account2.address                                   
      })
      liquidity = (await kommodo.lender(tick, account2.address)).liquidity
      //Swap to increase above lend tick
      await mockRouter.connect(account2).swap(mockRouter.address, false, "2000000000000000000", "1461446703485210103287273052203988822378723970341", "0x")
      //Withdraw interest from lend position
      balanceA_before = await tokenA.balanceOf(account2.address)
      balanceB_before = await weth.balanceOf(account2.address)
      await kommodo.connect(account2).withdraw(tick, account2.address, 2000, 2000)
      //Check interest swap withdraw
      balanceA_after = await tokenA.balanceOf(account2.address)
      balanceB_after = await weth.balanceOf(account2.address)
      expect((balanceA_after - balanceA_before).toString()).to.equal('0')
      expect((balanceB_after - balanceB_before).toString()).to.not.equal('0')
      //Return to original SQRT price
      await mockRouter.connect(account2).swap(mockRouter.address, true, "100", "79228162514264337593543950336", "0x")
    })
  })


  describe("Kommodo_test_unhappy", function () {         
    //Provide()
    it('Should fail provide for zero amountA and amountB', async function () {
      //Fail provide() zero amount -> fails in connector call pool.mint(), zero liquidity;
      await expect(kommodo.connect(account2).provide(
        {
          tickLower: ticklower,                           
          liquidity: 0,                           
          amountMaxA: 0,                   
          amountMaxB: 0,  
          sender: account2.address                                   
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
      let KommodoNAMM = await kommodoFactory.kommodo("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002", 500)
      kommodoNAMM = new Contract(KommodoNAMM, artifacts.Kommodo.abi, provider)
      //Check kommodo exists and no AMM pool exists
      expect(KommodoNAMM).to.not.equal("0x0000000000000000000000000000000000000000")
      expect(await factory.getPool("0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002", 500)).to.equal("0x0000000000000000000000000000000000000000") 
      //Fail provide() no AMM pool -> fails in connector call pool.slot0(), no deployed contract
      await expect(kommodoNAMM.connect(account2).provide(
        {
          tickLower: ticklower,
          liquidity: 10,                           
          amountMaxA: 100,                   
          amountMaxB: 0,                             
          sender: account2.address                                  
        })).to.be.reverted
    })   
    it('Should fail provide if ticklower >= tickmax', async function () {
      //AMM set max tick rounded per 10 because of spacing
      MAX_TICK = 887272 - 2
      //Fail provide() ticklower >= tickmax -> fails in connector call TickMath.getSqrtRatioAtTick(tickUpper), above tickmax 
      await expect(kommodo.connect(account2).provide(
        {
          tickLower: MAX_TICK,  
          liquidity: 10,                           
          amountMaxA: 100,                   
          amountMaxB: 0,                                                        
        })).to.be.reverted
    }) 
    it('Should fail take no position', async function () {
      slot0 = await pool.slot0()
      ticklower = nearestUsableTick(slot0.tick, spacing) + 2 * spacing
      deposit = 100
      await kommodo.connect(account2).provide({
        tickLower: ticklower,   
        liquidity: 100000,                           
        amountMaxA: deposit,                   
        amountMaxB: 0,                        
        amountA: deposit,                   
        amountB: 0                                  
      })
      let kommodo_position = await kommodo.lender(ticklower, account2.address) 
      assets = await kommodo.assets(ticklower)
      expect(kommodo_position.liquidity.toString()).to.not.equal('0')
      expect(assets.liquidity.toString()).to.not.equal('0')
      //account3 no open position
      await expect(kommodo.connect(account3).take(
        {
          tickLower: ticklower,
          liquidity: 1,
          amountMinA: 0,
          amountMinB: 0 
          }
      )).to.be.revertedWith("panic code 0x11")
    }) 
    it('Should fail take locked liquidity', async function () {
      assets = await kommodo.assets(ticklower)
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: ticklower, 
        liquidityBor: assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: 10000, 
        interest: interest
      })
      assets = await kommodo.assets(ticklower)
      expect(assets.liquidity.toString()).to.equal(assets.locked.toString())
      await expect( kommodo.connect(account2).take(
        {
          tickLower: ticklower,
          liquidity: 1,
          amountMinA: 0,
          amountMinB: 0 
          }
      )).to.be.revertedWith("take: insufficient liquidity")
    })
    it('Should fail open for insufficient funds', async function () {
      await kommodo.connect(account2).provide({
        tickLower: ticklower,                           
        liquidity: 10,                           
        amountMaxA: deposit,                   
        amountMaxB: 0,                                     
      })
      assets = await kommodo.assets(ticklower)
      balanceA_before = await tokenA.balanceOf(account3.address)
      balanceB_before = await weth.balanceOf(account3.address)
      expect(balanceA_before).to.equal(0)
      expect(balanceB_before).to.equal(0)
      await expect(kommodo.connect(account3).open(
        {
          token0: false,
          tickBor: ticklower, 
          liquidityBor: 100, 
          borAMin: 0,
          borBMin: 0, 
          colAmount: 200, 
          interest: interest                              
        }
      )).to.be.revertedWith("STF")
    })
    it('Should fail adjust non existent loan', async function () {
        await expect(kommodo.connect(account2).adjust(
          {
            token0: true,
            tickBor: ticklower,  
            liquidityBor: 1, 
            borAMax: BigInt(amount),
            borBMax: BigInt(amount),
            amountCol: 0, 
            interest:  100                            
          }
        )).to.be.revertedWith("adjust: no open loan")
    })
   
    it('Should fail close non existent loan', async function () {
        await expect(kommodo.connect(account2).close({
          token0: true,                             
          owner:  account2.address,                  
          tickBor: ticklower,                          
          borAMax:  BigInt(amount),
          borBMax:  BigInt(amount)
      })).to.be.revertedWith("close: no open loan")
    }) 
    it('Should fail close non owner active loan', async function () {
        await kommodo.connect(account2).open(
        {
          token0: false,
          tickBor: ticklower, 
          liquidityBor: 1, 
          borAMin: 0,
          borBMin: 0, 
          colAmount: 200, 
          interest: interest                              
        })
        await expect(kommodo.connect(account3).close({
          token0: false,                             
          owner:  account2.address,                  
          tickBor: ticklower,                          
          borAMax:  BigInt(amount),
          borBMax:  BigInt(amount)
        })).to.be.revertedWith("close: not authorized")
    })
  }) 
  describe("Kommodo_NFT_Lender_test_happy", function () {        
    before(async function () {
      //Mint tokens and approve kommodo
      base = new bn(10)
      amount = base.pow("18")
      await tokenA.connect(account2).mint(amount.toString())
      await weth.connect(account2).deposit({value: amount.toString()})
      await tokenA.connect(account2).approve(nonfungibleLendManager.address, amount.toString())
		  await weth.connect(account2).approve(nonfungibleLendManager.address, amount.toString())
      await tokenA.connect(account1).mint(amount.toString())
      await weth.connect(account1).deposit({value: amount.toString()})
      await tokenA.connect(account1).approve(nonfungibleLendManager.address, amount.toString())
		  await weth.connect(account1).approve(nonfungibleLendManager.address, amount.toString())
    });
    it('Should mint NFT', async function () { 
      before_balanceA = await tokenA.balanceOf(account2.address)
      before_balanceB = await weth.balanceOf(account2.address)
      nft_balance = await nonfungibleLendManager.balanceOf(account2.address)
      expect(nft_balance).to.equal('0')
      //Approve pool for NFT
      await nonfungibleLendManager.connect(account2).poolApprove(
          weth.address,
          tokenA.address,
          500
      )
      //Mint NFT lending position
      deposit = 100
      await nonfungibleLendManager.connect(account2).mint(
        {
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: ticklower + 2*spacing,
          liquidity: 200000,                           
          amountMaxA: deposit,                   
          amountMaxB: deposit                              
        }
      )
      //Check position
      kommodo_position = await kommodo.assets(ticklower + 2*spacing)
      after_balanceA = await tokenA.balanceOf(account2.address)
      after_balanceB = await weth.balanceOf(account2.address)
      expect(kommodo_position.liquidity.toString()).to.not.equal('0')
      expect(before_balanceA.sub(after_balanceA)).to.equal(deposit)
      expect(before_balanceB.sub(after_balanceB)).to.equal(0)
      //check nft
      nft_balance = await nonfungibleLendManager.balanceOf(account2.address)
      expect(nft_balance).to.equal('1')
      tokenId = await nonfungibleLendManager.tokenOfOwnerByIndex(account2.address, nft_balance-1)
      expect(tokenId).to.equal('1')
      nft_position = await nonfungibleLendManager.position(tokenId)
      expect(nft_position.pool).to.equal(kommodo.address)
      expect(nft_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(nft_position.locked).to.equal(nft_position.liquidity)
    })
    it('Should provide NFT', async function () { 
      before_balanceA = await tokenA.balanceOf(account2.address)
      before_balanceB = await weth.balanceOf(account2.address)
      //Add to NFT lending position
      deposit = 100
      await nonfungibleLendManager.connect(account2).provide(
        {
          tokenId: 1,
          assetA: weth.address,
          assetB: tokenA.address,
          poolFee: 500,
          tickLower: ticklower + 2*spacing,                           
          liquidity: 200000,                           
          amountMaxA: deposit,                   
          amountMaxB: deposit,    
        }
      )
      //Check position
      kommodo_position = await kommodo.assets(ticklower + 2*spacing)
      after_balanceA = await tokenA.balanceOf(account2.address)
      after_balanceB = await weth.balanceOf(account2.address)
      expect(before_balanceA.sub(after_balanceA)).to.equal(deposit)
      expect(before_balanceB.sub(after_balanceB)).to.equal(0)
      nft_balance = await nonfungibleLendManager.balanceOf(account2.address)
      expect(nft_balance).to.equal('1')
      tokenId = await nonfungibleLendManager.tokenOfOwnerByIndex(account2.address, nft_balance-1)
      expect(tokenId).to.equal('1')
      nft_position = await nonfungibleLendManager.position(tokenId)
      expect(nft_position.pool).to.equal(kommodo.address)
      expect(nft_position.liquidity).to.equal(kommodo_position.liquidity)
    })
    it('Should take NFT', async function () { 
      //Take from NFT lending position
      let liq_nft = (await nonfungibleLendManager.connect(account2).position(1)).liquidity
      before_balanceA = await tokenA.balanceOf(account2.address)
      before_balanceB = await weth.balanceOf(account2.address)
      await nonfungibleLendManager.connect(account2).take(
        {
          tokenId: 1,
          liquidity: liq_nft.div(2).toString(),                         
          amountMinA: 0,                   
          amountMinB: 0,
          recipient: account2.address      
        }
      )
      //Check position
      after_balanceA = await tokenA.balanceOf(account2.address)
      after_balanceB = await weth.balanceOf(account2.address)
      kommodo_position = await kommodo.assets(ticklower + 2*spacing)
      nft_balance = await nonfungibleLendManager.balanceOf(account2.address)
      expect(nft_balance).to.equal('1')
      tokenId = await nonfungibleLendManager.tokenOfOwnerByIndex(account2.address, nft_balance-1)
      expect(tokenId).to.equal('1')
      nft_position = await nonfungibleLendManager.position(tokenId)
      expect(nft_position.pool).to.equal(kommodo.address)
      expect(nft_position.liquidity).to.equal(liq_nft.div(2))
      expect(nft_position.liquidity).to.equal(kommodo_position.liquidity)
      expect(nft_position.withdrawB).to.equal("0") 
      expect(after_balanceA.sub(before_balanceA)).to.equal("99") 
      expect(after_balanceB.sub(before_balanceB)).to.equal("0") 
    })  
    it('Should withdraw NFT', async function () { 
      position_NFT = await nonfungibleLendManager.connect(account2).position(1)
      let ticklower = position_NFT[1]
      //Add interest through borrow
      assets = await kommodo.assets(ticklower)
      let feegrowth1_before = assets.feeGrowth1X128
      liquidity = assets.liquidity - assets.locked
      interest = 10
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: ticklower, 
        liquidityBor: liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: 10000, 
        interest: interest
      })
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: ticklower,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      assets = await kommodo.assets(ticklower)
      let feegrowth1_after = assets.feeGrowth1X128
      expect(feegrowth1_after).not.equal(feegrowth1_before)
      //Withdraw from NFT lending position
      before_balanceA = await tokenA.balanceOf(account2.address)
      before_balanceB = await weth.balanceOf(account2.address)
      await nonfungibleLendManager.connect(account2).withdraw(
        {
          tokenId: 1,                   
          amountA: deposit,                   
          amountB: deposit,    
          recipient: account2.address   
        }
      )
      after_balanceA = await tokenA.balanceOf(account2.address)
      after_balanceB = await weth.balanceOf(account2.address)
      expect(after_balanceA.sub(before_balanceA)).to.equal("0") 
      expect(after_balanceB.sub(before_balanceB)).to.equal("5") 
    })
  })
  describe("Kommodo_test_solvency_requirement", function () {   
    it('Collateral token0 - borrow CLP tick > current tick - tick increases above', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) + 10 * spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99950363n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick, 
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: 0,                          
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)
      //borrow - collateral token0 == true
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- only balance0 difference fee + margin 
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      expect(balance0_before.sub(balance0_after)).to.equal(margin.add(fee).add(1)) //rounding 1 because of rounding down in borrow amount
      expect(balance1_after).to.equal(balance1_before)  
      //increase pool tick above CLP tick (max sqrt)
      let new_sqrt = 1461446703485210103287273052203988822378723970341n
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.below(slot0.tick)
      //Close position should pay token1 - return col amount0
      await kommodo.connect(account1).close({
        token0: true,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect(balance0_after_close.sub(balance0_after)).to.equal(collateral_amount)
      expect(balance1_after_close.sub(balance1_after)).to.be.below(0) //pay token1
      //Proof solvency - expect both tokens 18 decimals
      let price_token1_per_token0 = (new_sqrt / (BigInt(2)**BigInt(96)))**BigInt(2) // curren pool price = token1/token0
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let collateral_value_as_token0 = collateral_amount
      let borrow_value_as_token0 = -Number(balance1_after_close.sub(balance1_after)) * price_token0_per_token1
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_amount * Number(price_token1_per_token0)
      let borrow_value_as_token1 = -Number(balance1_after_close.sub(balance1_after))
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000", old_sqrt, "0x")
    })
    it('Collateral token0 - borrow CLP tick < current tick - tick decreases below', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) - 11 * spacing
      //lender deposit token1 -> amountB
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99949889n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,
          liquidity: liquidity_in,                           
          amountMaxA: 0,                   
          amountMaxB: deposit,  
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.below(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)
      //borrow - collateral token0 == true
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- receive token1 and deposit token0
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)           
      expect(balance0_before.sub(balance0_after)).to.equal(collateral_amount.add(fee)) 
      expect(balance1_after.sub(balance1_before)).to.equal(deposit - 1n) //rounding 1 because of rounding down in borrow amount
      //decrease pool tick below CLP tick (min sqrt)
      let new_sqrt = 4295128740n
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.above(slot0.tick)    
      //Close position should pay token0 - return col amount0
      await kommodo.connect(account1).close({
        token0: true,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect(balance0_after_close.sub(balance0_after)).to.be.above(0) // pay(deposit amount) - receive(collateral) = positive
      expect(balance1_after_close).to.equal(balance1_after)  
      //Proof solvency - expect both tokens 18 decimals
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0
      let borrow_repay_token0 = -(balance0_after_close.sub(balance0_after) - collateral_amount)
      let collateral_value_as_token0 = collateral_amount
      let borrow_value_as_token0 = borrow_repay_token0
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_amount * Number(price_token1_per_token0)
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000", old_sqrt, "0x")
    })
    it('Collateral token1 - borrow CLP > current tick - tick increases above', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) + 20 * spacing 
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99950561n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick, 
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: 0,                          
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)      
      //borrow - collateral token1 == false
      let coll_increase = deposit + 2275389n  //increase collateral to match borrow value @ borrow price CLP 
      let margin = await kommodo.getFee(coll_increase)
      let collateral_amount = (BigNumber.from(coll_increase)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- receive token0 and deposit token1
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      expect(balance0_after.sub(balance0_before)).to.equal(deposit-1n) //rounding 1 because of rounding down in borrow amount
      expect(balance1_before.sub(balance1_after)).to.equal(collateral_amount.add(fee))
      //increase pool tick above CLP tick (max sqrt)
      let new_sqrt = 1461446703485210103287273052203988822378723970341n
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.below(slot0.tick)
      //Close position should pay token1 - return col amount1
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect(balance0_after_close).to.equal(balance0_after)
      expect(balance1_after_close.sub(balance1_after)).to.be.above(0) //pay(deposit amount) - receive(collateral) = positive  
      //Proof solvency - expect both tokens 18 decimals
      let price_token1_per_token0 = (new_sqrt / (BigInt(2)**BigInt(96)))**BigInt(2) // curren pool price = token1/token0
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let borrow_repay_token1 = -(balance1_after_close.sub(balance1_after) - collateral_amount)     
      let collateral_value_as_token0 = collateral_amount * price_token0_per_token1
      let borrow_value_as_token0 = borrow_repay_token1 * price_token0_per_token1
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_amount
      let borrow_value_as_token1 = borrow_repay_token1
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", old_sqrt, "0x")
    })
    it('Collateral token1 - borrow CLP < current tick - tick decreases below', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) - 20 * spacing 
      //lender deposit token1 -> amountB
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99950438n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,  
          liquidity: liquidity_in,                           
          amountMaxA: 0,                   
          amountMaxB: deposit,                            
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)   
      expect(clp_tick).to.be.below(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)      
      //borrow - collateral token1 == false
      let coll_increase = deposit
      let margin = await kommodo.getFee(coll_increase)
      let collateral_amount = (BigNumber.from(coll_increase)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)     
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- only balance1 difference fee + margin 
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      expect(balance0_after).to.equal(balance0_before) 
      expect(balance1_before.sub(balance1_after)).to.equal(margin.add(fee).add(1)) //rounding 1 because of rounding down in borrow amount
      //increase pool tick above CLP tick (max sqrt)
      let new_sqrt = 4295128740n
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.above(slot0.tick)
      //Close position should pay token0 - return col amount1
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect((balance0_after_close).sub(balance0_after)).to.be.below(0) //repay token0
      expect(balance1_after_close.sub(balance1_after)).to.equal(collateral_amount)
      //Proof solvency - expect both tokens 18 decimals
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1  
      let collateral_value_as_token0 = collateral_amount * price_token0_per_token1
      let borrow_value_as_token0 = -(balance0_after_close).sub(balance0_after)
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_amount
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", old_sqrt, "0x")
    })   
    //special case - inside range 
    it('Collateral token0 - borrow CLP inside current tick - tick decreases below', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      new_tick = nearestUsableTick(slot0.tick, spacing) + 1000 * spacing
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(new_tick - spacing)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**new_tick) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)
      clp_tick = new_tick - spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: deposit, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.below(slot0.tick)
      expect(clp_tick + spacing).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)
      //borrow - collateral token0 == true
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- receive token0 and token1 solvent
      kommodo_assets = await kommodo.assets(clp_tick) 
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      //check solvency
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let collateral_value_as_token0 = collateral_amount
      let borrow_received0 = Number(balance0_after.sub(balance0_before).add(collateral_amount.add(fee)))
      let borrow_received1 = Number(balance1_after.sub(balance1_before))
      let borrow_value_as_token0 = borrow_received0 + borrow_received1 * price_token0_per_token1
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_value_as_token0 * Number(price_token1_per_token0)
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))  
      //decrease pool tick below CLP tick (min sqrt)
      new_sqrt = 4295128740n
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.above(slot0.tick)
      //Close position should pay token0 - return col amount0
      await kommodo.connect(account1).close({
        token0: true,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect(balance0_after_close.sub(balance0_after)).to.be.above(0) //collateral received > borrow repayed 
      expect(balance1_after_close).to.equal(balance1_after) 
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", old_sqrt, "0x") 
    })
    it('Collateral token1 - borrow CLP inside current tick - tick increases above', async function () {     
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      new_tick = nearestUsableTick(slot0.tick, spacing) - 1002 * spacing
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(new_tick - spacing)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**new_tick) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)
      clp_tick = new_tick - spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: deposit, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.below(slot0.tick)
      expect(clp_tick + spacing).to.be.above(slot0.tick)       
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address) 
      //borrow - collateral token1 == false
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })     
      //check borrow -- receive token0 and token1 solvent
      kommodo_assets = await kommodo.assets(clp_tick) 
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      //check solvency
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let collateral_value_as_token0 = collateral_amount * price_token0_per_token1
      let borrow_received0 = Number(balance0_after.sub(balance0_before))
      let borrow_received1 = Number(balance1_after.sub(balance1_before).add(collateral_amount.add(fee)))
      let borrow_value_as_token0 = borrow_received0 + borrow_received1 * price_token0_per_token1
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_value_as_token0 * Number(price_token1_per_token0)
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))  
      //increase pool tick above CLP tick (min sqrt)
      new_sqrt = 1461446703485210103287273052203988822378723970341n
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.below(slot0.tick)      
      //Close position should pay token1 - return col amount1
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      expect(balance0_after_close).to.equal(balance0_after) 
      expect(balance1_after_close.sub(balance1_after)).to.be.above(0) //collateral received > borrow repayed 
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", old_sqrt, "0x") 
    })
    it('Collateral token0 - borrow CLP tick > current tick - tick increases inside', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) + 10 * spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99950313n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: 0, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)         
      expect(clp_tick).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)
      //borrow - collateral token0 == true
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)
      await kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- only balance0 difference fee + margin 
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address) 
      expect(balance0_before.sub(balance0_after)).to.equal(margin.add(fee).add(1)) //rounding 1 because of rounding down in borrow amount
      expect(balance1_after).to.equal(balance1_before)  
      //increase pool tick inside CLP tick
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick + spacing)) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.below(slot0.tick)
      expect(clp_tick + spacing).to.be.above(slot0.tick)      
      //Close position should pay token0 and token1 - return col amount0
      await kommodo.connect(account1).close({
        token0: true,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      //check solvency
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let collateral_value_as_token0 = collateral_amount 
      let borrow_repayed0 = -Number(balance0_after_close.sub(balance0_after).sub(collateral_amount.add(fee)))
      let borrow_repayed1 = -Number(balance1_after_close.sub(balance1_after))
      let borrow_value_as_token0 = borrow_repayed0 + borrow_repayed1 * price_token0_per_token1
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_value_as_token0 * Number(price_token1_per_token0)
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))  
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", old_sqrt, "0x")
    })
    it('Collateral token1 - borrow CLP tick < current tick - tick decreases inside', async function () {
      let token0 = tokenA.address < weth.address ? tokenA : weth
      let token1 = tokenA.address > weth.address ? tokenA : weth
      slot0 = await pool.slot0()
      let old_sqrt = slot0.sqrtPriceX96
      clp_tick = nearestUsableTick(slot0.tick, spacing) - 30 * spacing
      //lender deposit token1 -> amountB
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99950685n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: 0,                   
          amountMaxB: deposit, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)   
      expect(clp_tick).to.be.below(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      let balance0_before = await token0.balanceOf(account1.address)
      let balance1_before = await token1.balanceOf(account1.address)        
      //borrow - collateral token1 == false
      let coll_increase = deposit
      let margin = await kommodo.getFee(coll_increase)
      let collateral_amount = (BigNumber.from(coll_increase)).add(margin)
      let fee = await kommodo.getFee(collateral_amount)     
      await kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })
      //check borrow -- only balance0 difference fee + margin 
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(kommodo_assets.liquidity)  
      let balance1_after = await token1.balanceOf(account1.address)
      let balance0_after = await token0.balanceOf(account1.address)
      expect(balance0_after).to.equal(balance0_before) 
      expect(balance1_before.sub(balance1_after)).to.equal(margin.add(fee).add(1)) //rounding 1 because of rounding down in borrow amount       
      //decrease pool tick inside CLP tick 
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick - spacing)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick)) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      await mockRouter.connect(account2).swap(mockRouter.address, true, "10000000000000000000", new_sqrt, "0x")
      slot0 = await pool.slot0()
      expect(new_sqrt).to.equal(slot0.sqrtPriceX96)  
      expect(clp_tick).to.be.above(slot0.tick)
      //Close position should pay token0 & token1 - return col amount1
      await kommodo.connect(account1).close({
        token0: false,                             
        owner:  account1.address,                  
        tickBor: clp_tick,                          
        borAMax: BigInt(amount),
        borBMax: BigInt(amount)
      })
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      let balance1_after_close = await token1.balanceOf(account1.address)
      let balance0_after_close = await token0.balanceOf(account1.address)
      //check solvency
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let collateral_value_as_token0 = collateral_amount * price_token0_per_token1
      let borrow_repayed0 = -Number(balance0_after_close.sub(balance0_after))
      let borrow_repayed1 = -Number(balance1_after_close.sub(balance1_after).sub(collateral_amount.add(fee)))
      let borrow_value_as_token0 = borrow_repayed0 + borrow_repayed1 * price_token0_per_token1  
      expect(borrow_value_as_token0).to.be.below(Number(collateral_value_as_token0))
      let collateral_value_as_token1 = collateral_value_as_token0 * Number(price_token1_per_token0)
      let borrow_value_as_token1 = borrow_value_as_token0 * price_token1_per_token0
      expect(borrow_value_as_token1).to.be.below(Number(collateral_value_as_token1))             
      //return sqrt pool original
      await mockRouter.connect(account2).swap(mockRouter.address, false, "10000000000000000000", old_sqrt, "0x")
    })
    //Unhappy cases - deposit slighthly insufficient collateral for borrow value
    it('Should fail insufficient token0 for borrow token0', async function () {
      slot0 = await pool.slot0()
      clp_tick = nearestUsableTick(slot0.tick, spacing) + 200 * spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99954816n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: 0, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)     
      expect(clp_tick).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      //borrow - collateral token0 == true
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin).sub(1) //sufficient collateral minus 1
      await expect(kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })).to.be.revertedWith("open: insufficient collateral for borrow")
    })
    it('Should fail insufficient token0 for borrow token1', async function () {
      slot0 = await pool.slot0()
      clp_tick = nearestUsableTick(slot0.tick, spacing) - 200 * spacing
      //lender deposit token1 -> amountB
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99954703n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: 0,                   
          amountMaxB: deposit, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)
      expect(clp_tick).to.be.below(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      //borrow - collateral token0 == true
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick + spacing)) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let adjusted_deposit = Math.round(Number(deposit) * price_token0_per_token1) //borrow -> 10n**8 * price_token0_per_token1
      let margin = await kommodo.getFee(adjusted_deposit)
      let collateral_amount = BigNumber.from(adjusted_deposit).add(margin).sub(1) //insufficient collateral based on borrow amount - small adjust for rounding to get within 1 of borrow value1
      await expect(kommodo.connect(account1).open({
        token0: true,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })).to.be.revertedWith("open: insufficient collateral for borrow")
    })
    it('Should fail insufficient token1 for borrow token0', async function () {
      slot0 = await pool.slot0()
      clp_tick = nearestUsableTick(slot0.tick, spacing) + 201 * spacing
      //lender deposit token0 -> amountA
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99954839n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: deposit,                   
          amountMaxB: 0, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)  
      expect(clp_tick).to.be.above(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0) 
      //borrow - collateral token1 == false
      new_sqrt_low = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick)) * (2**96)))
      new_sqrt_high = BigInt(Math.floor(Math.sqrt(1.0001**(clp_tick + spacing)) * (2**96)))
      new_sqrt = (new_sqrt_high + new_sqrt_low) / 2n
      let price_token1_per_token0 = (Number(new_sqrt) / 2**96)**2 // curren pool price = token1/token0     
      let price_token0_per_token1 = 1/Number(price_token1_per_token0) // convert price = token0/token1
      let adjusted_deposit = Math.round(Number(deposit) * price_token1_per_token0) //borrow -> 10n**8 * price_token0_per_token1
      let margin = await kommodo.getFee(adjusted_deposit)
      let collateral_amount = BigNumber.from(adjusted_deposit).add(margin).sub(1) //insufficient collateral based on borrow amount - small adjust for rounding to get within 1 of borrow value1
      await expect(kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })).to.be.revertedWith("open: insufficient collateral for borrow")
    })
    it('Should fail insufficient token1 for borrow token1', async function () {
      slot0 = await pool.slot0()
      clp_tick = nearestUsableTick(slot0.tick, spacing) - 201 * spacing
      //lender deposit token1 -> amountAB
      let liquidity_in = 10n**8n 
      deposit = 10n**8n - 99954726n
      await kommodo.connect(account2).provide(
        {
          tickLower: clp_tick,                           
          liquidity: liquidity_in,                           
          amountMaxA: 0,                   
          amountMaxB: deposit, 
          sender: account2.address                                   
        }
      )
      kommodo_assets = await kommodo.assets(clp_tick)     
      expect(clp_tick).to.be.below(slot0.tick)
      expect(kommodo_assets.liquidity).to.not.equal(0)  
      expect(kommodo_assets.locked).to.equal(0)  
      //borrow - collateral token1 == false
      let margin = await kommodo.getFee(deposit)
      let collateral_amount = (BigNumber.from(deposit)).add(margin).sub(1) //sufficient collateral minus 1
      await expect(kommodo.connect(account1).open({
        token0: false,
        tickBor: clp_tick, 
        liquidityBor: kommodo_assets.liquidity, 
        borAMin: 0,
        borBMin: 0, 
        colAmount: collateral_amount, 
        interest: 0
      })).to.be.revertedWith("open: insufficient collateral for borrow")
    })
  })  
})

