# 🔐 Security Review — Kommodo-STCLP

---

## Scope

|                                  |                                                                                                        |
| -------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Mode**                         | ALL                                                                                                    |
| **Files reviewed**               | `Kommodo.sol` · `Connector.sol` · `NonfungibleLendManager.sol`<br>`KommodoFactory.sol` · `libraries/LiquidityAmounts.sol` · `libraries/PoolAddress.sol`<br>`libraries/TickMath.sol` · `libraries/SqrtPriceMath.sol` · `libraries/CallbackValidation.sol`<br>`libraries/FullMath.sol` · `libraries/SafeCast.sol` |
| **Confidence threshold (1-100)** | 80                                                                                                     |
| **Date**                         | 2026-03-06                                                                                             |

---

## Findings

[85] **1. Missing Slippage Protection in `adjust()` Exposes Borrowers to Sandwich Attacks**

`Kommodo.adjust` · Confidence: 85 · **Fixed**

**Description**
`adjust()` calls the exact-liquidity `addLiquidity` overload with no `amountMax` guard on the tokens pulled from `msg.sender` via the Uniswap V3 mint callback; a sandwich attacker can move pool price before the transaction lands, forcing the borrower to pay significantly more tokens than expected to remint the exact same liquidity units.

**Fix**

```diff
+ // Add to AdjustParams: uint256 amount0MaxRepay; uint256 amount1MaxRepay;
  if (params.liquidityBor > 0) {
      (, borA, borB, ) = addLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, params.liquidityBor);
+     require(borA <= params.amount0MaxRepay && borB <= params.amount1MaxRepay, "adjust: slippage");
  }
```

---

[80] **2. ERC777 / Transfer-Hook Token Bypasses Preemptive Liquidity Check in `Kommodo.open()`**

`Kommodo.open` · Confidence: 80 · **Mitigated**

**Description**
`open()` performs its liquidity sufficiency check (`_assets.liquidity - _assets.locked >= params.liquidityBor`) before calling `setInterest()`, which internally executes `safeTransferFrom`; if the collateral token implements ERC777 or a `tokensToSend` hook, the callback re-enters `open()` while `_assets.locked` still reflects its pre-call value, allowing the preemptive check to pass again. No actual overborrowing occurs — the downstream `removeLiquidity → pool.burn()` fails if Uniswap V3 does not hold sufficient physical liquidity — but the guard's intent is defeated. Mitigated by moving the `require` to immediately after `setInterest()`.

**Fix**

```diff
  function open(OpenParams calldata params) public {
      Assets storage _assets = assets[params.tickBor];
      Loan storage loan = borrower[getKey(msg.sender, params.tickBor, params.token0)];
-     require(_assets.liquidity - _assets.locked >= params.liquidityBor, "open: insufficient liquidity");
      require(getFee(params.colAmount).toUint128() > 0, "open: no zero fee");
      if (params.token0) {
          TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), params.colAmount + getFee(params.colAmount).toUint128());
          ...
      } else { ... }
      setInterest(params.token0, params.tickBor, params.interest);
+     require(_assets.liquidity - _assets.locked >= params.liquidityBor, "open: insufficient liquidity");
      _assets.locked += params.liquidityBor;
      ...
```

---

[80] **3. ERC721 Callback in `NonfungibleLendManager.mint()` Allows Caller to Lock Their Own Liquidity**

`NonfungibleLendManager.mint` · Confidence: 80 · **Fixed**

**Description**
`_safeMint(msg.sender, tokenId)` is called before `position[tokenId]` is written; a malicious `onERC721Received` callback finds the position struct at zero-values and can call `burn()` (which previously passed the empty-position check), resulting in the caller's committed liquidity becoming permanently locked inside Kommodo with no recovery path.

**Fix**

```diff
  // In burn(): guard against uninitialized positions
+ require(_position.blocknumber != 0, "burn: no position");
```

---

[80] **4. Fee-on-Transfer Tokens Cause Undercollateralized Loan Accounting**

`Kommodo.open` · Confidence: 80 · **Fixed**

**Description**
The protocol targets standard ERC20 tokens; fee-on-transfer tokens fall outside the intended design. However, if such a token is used as collateral, `loan.amountCol += params.colAmount` records the nominal amount while `safeTransferFrom` delivers less, causing the recorded collateral to exceed what the contract actually holds. The added balance check directly mitigates any such discrepancy at the point of deposit.

**Fix**

```diff
+ uint256 balBefore = IERC20(token).balanceOf(address(this));
  TransferHelper.safeTransferFrom(token, msg.sender, address(this), params.colAmount + fee);
+ uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
+ uint128 actualCol = uint128(received - fee);
- loan.amountCol += params.colAmount;
+ loan.amountCol += actualCol;
```

---

[80] **5. Zero-Amount Transfer in `Kommodo.withdraw()` and `Kommodo.close()` with Non-Standard Tokens**

`Kommodo.withdraw` · `Kommodo.close` · Confidence: 80 · **Fixed**

**Description**
The protocol targets standard ERC20 tokens; certain non-standard implementations revert on zero-value transfers. `TransferHelper.safeTransfer` is called unconditionally for both token amounts in `withdraw()` and `close()` even when a value is zero, which would permanently block these functions when paired with such tokens. Adding value guards before each transfer eliminates this risk regardless of token behavior.

**Fix**

```diff
- TransferHelper.safeTransfer(tokenA, recipient, withdrawA);
- TransferHelper.safeTransfer(tokenB, recipient, withdrawB);
+ if (withdrawA > 0) TransferHelper.safeTransfer(tokenA, recipient, withdrawA);
+ if (withdrawB > 0) TransferHelper.safeTransfer(tokenB, recipient, withdrawB);

  // close():
- TransferHelper.safeTransfer(token, msg.sender, unused.toUint128());
+ if (unused > 0) TransferHelper.safeTransfer(token, msg.sender, unused.toUint128());
```

---

## Findings List

| # | Confidence | Title | Status |
|---|---|---|---|
| 1 | [85] | Missing Slippage Protection in `adjust()` — Sandwich Attack | Fixed |
| 2 | [80] | ERC777 Token Bypasses Preemptive Liquidity Check in `open()` | Mitigated |
| 3 | [80] | ERC721 Callback in `mint()` — Caller Can Lock Own Liquidity | Fixed |
| 4 | [80] | Fee-on-Transfer Token — Undercollateralized Loan Accounting | Fixed |
| 5 | [80] | Zero-Amount Transfer DoS in `withdraw()` and `close()` | Fixed |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
