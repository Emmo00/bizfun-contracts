# BizFun Prediction Market Protocol — SKILL Document

> **Purpose:** This document describes the BizFun prediction market protocol, its deployed contract addresses, every public function signature, the full interaction flow, and the underlying LMSR pricing math.

---

## Deployments

### Base Sepolia (Testnet) — Chain ID `84532`

| Contract                              | Address                                      | Notes                                             |
| ------------------------------------- | -------------------------------------------- | ------------------------------------------------- |
| **MockUSDC**                          | `0x0d0ec10cc2eaeb6dbc9127fb98c9ebbfc029b8c9` | ERC-20, 6 decimals, has `faucet()`                |
| **PredictionMarket (implementation)** | `0x6438ef1eb2162a3f8e1d03674ba841bd16748d96` | Do NOT interact directly — clone template only    |
| **PredictionMarketFactory**           | `0xc2271d03612cdae45be35709193ac3dfc51dac03` | Entry point for creating and discovering markets  |

> **Collateral token:** USDC (6 decimals). On testnet the MockUSDC above is used. Call `faucet()` on MockUSDC to mint 1,000 USDC to your address for free.

### Base Mainnet — Chain ID `8453`

| Contract                              | Address | Notes              |
| ------------------------------------- | ------- | ------------------ |
| **USDC**                              | _TBD_   | Native USDC on Base |
| **PredictionMarket (implementation)** | _TBD_   | Clone template     |
| **PredictionMarketFactory**           | _TBD_   | Entry point        |

### BNB Smart Chain (BSC) — Chain ID `56`

| Contract                              | Address | Notes          |
| ------------------------------------- | ------- | -------------- |
| **USDC**                              | _TBD_   | USDC on BSC    |
| **PredictionMarket (implementation)** | _TBD_   | Clone template |
| **PredictionMarketFactory**           | _TBD_   | Entry point    |

---

## Protocol Overview

BizFun is a prediction market protocol powered by the **$BizMart** AI agent. It lets businesses, startups, ideas, and careers get attention and funding through on-chain prediction markets. Users create markets around measurable outcomes (e.g., _"Will this business make $3,000 in the next 30 days?"_), and both AI agents and humans trade YES/NO shares using USDC as collateral.

### Architecture

```
                        ┌─────────────────────────┐
                        │  PredictionMarketFactory │
                        │  (single deployment)     │
                        └────────┬────────────────┘
                                 │ createMarket()
                   ┌─────────────┼─────────────┐
                   ▼             ▼             ▼
           ┌──────────┐  ┌──────────┐  ┌──────────┐
           │ Market 0 │  │ Market 1 │  │ Market N │   ← EIP-1167 minimal proxy clones
           │ (clone)  │  │ (clone)  │  │ (clone)  │
           └──────────┘  └──────────┘  └──────────┘
```

- **Factory pattern** with EIP-1167 minimal proxy clones — each new market costs ~45 bytes of on-chain bytecode.
- **LMSR (Logarithmic Market Scoring Rule)** automated market maker for continuous pricing.
- **USDC collateral** (ERC-20, 6 decimals) — all costs and payouts denominated in USDC.
- **Oracle-based resolution** — a designated oracle address resolves market outcomes.
- **Off-chain metadata** — each market stores a `metadataURI` (e.g. IPFS link) with human-readable prediction details.

---

## Fee Structure

| Parameter                  | Default Value       | Description                                                          |
| -------------------------- | ------------------- | -------------------------------------------------------------------- |
| `MAX_CREATION_FEE`         | `1000e6` ($1,000)   | Hard cap on creation fee — immutable constant in factory             |
| `creationFee`              | `10e6` ($10 USDC)   | Total fee charged to market creator — adjustable by factory owner    |
| `initialLiquidity`         | `5e6` ($5 USDC)     | Portion of fee seeded as balanced YES/NO liquidity into new market   |
| Protocol revenue per market| `5e6` ($5 USDC)     | Retained by factory (`creationFee - initialLiquidity`), withdrawable |
| MockUSDC `FAUCET_AMOUNT`   | `1_000e6` ($1,000)  | Testnet faucet drip per call                                         |

---

## Market Lifecycle & States

Every `PredictionMarket` has a `MarketState` enum:

| State      | Numeric Value | Description                                                                 |
| ---------- | ------------- | --------------------------------------------------------------------------- |
| `OPEN`     | `0`           | Trading is active. Users can buy/sell YES and NO shares.                    |
| `CLOSED`   | `1`           | Trading deadline has passed. No more buys/sells. Awaiting oracle resolution.|
| `RESOLVED` | `2`           | Oracle has declared the outcome. Winners can call `redeem()`.               |

### Resolution Outcomes

| `resolvedOutcome` value | Meaning     | Who gets paid                        |
| ----------------------- | ----------- | ------------------------------------ |
| `1`                     | **YES wins**| Holders of YES shares call `redeem()`|
| `2`                     | **NO wins** | Holders of NO shares call `redeem()` |

### Timeline

```
 Market Created          tradingDeadline           resolveTime
      │                        │                        │
      ├────── OPEN ────────────┤                        │
      │  (buy/sell YES/NO)     │                        │
      │                        ├──── CLOSED ────────────┤
      │                        │  (no trading)          │
      │                        │                        ├──── RESOLVED ────
      │                        │                        │  (redeem payouts)
```

---

## Complete Interaction Flow

This section walks through every step an AI agent needs to interact with BizFun, from market creation to redemption.

### Step 1: Create a Prediction Market

**Contract:** `PredictionMarketFactory`

1. **Approve the factory** to spend your USDC (at minimum `creationFee` = 10e6):

```
USDC.approve(factoryAddress, 10000000)
```

2. **Call `createMarket`** on the factory:

```
factory.createMarket(
    address _oracle,           // Address authorized to resolve the market
    uint    _tradingDeadline,  // Unix timestamp — trading stops after this
    uint    _resolveTime,      // Unix timestamp — oracle can resolve after this (must be >= tradingDeadline)
    uint    _b,                // LMSR liquidity parameter in 1e18 scale (e.g. 1e18)
    string  _metadataUri       // IPFS/HTTP URI to off-chain metadata JSON
) returns (address marketAddress)
```

**What happens internally:**
- Factory pulls `creationFee` USDC from caller
- Deploys an EIP-1167 clone of the PredictionMarket implementation
- Calls `initialize(...)` on the clone
- Seeds balanced liquidity: buys `initialLiquidity / 2` YES shares and `initialLiquidity - initialLiquidity / 2` NO shares
- Transfers those liquidity shares to the caller (market creator)
- Stores market info and emits `MarketCreated` event
- Returns the new market's address

**Parameter guidance:**
- `_b` (liquidity parameter): Controls how sensitive prices are to trades. Higher `_b` = more liquidity, slower price movement. A typical value is `1e18` (1.0 in fixed-point). The maximum market-maker subsidy is bounded by `b * ln(2)`.
- `_tradingDeadline`: Must be in the future. Example: `block.timestamp + 7 days` = `block.timestamp + 604800`.
- `_resolveTime`: Must be `>=` `_tradingDeadline`. Example: `_tradingDeadline + 1 days`.
- `_metadataUri`: Must be non-empty. Typically an IPFS hash like `"ipfs://QmXyz..."`.

---

### Step 2: Discover Existing Markets

**Contract:** `PredictionMarketFactory`

```
factory.getMarketCount() returns (uint)             // Total number of deployed markets
factory.getMarket(uint id) returns (address)         // Market address by sequential ID (0-indexed)
factory.getMarketInfo(uint id) returns (MarketInfo)  // Full info struct by ID
factory.getAllMarkets() returns (address[])           // Array of all market addresses
factory.getMarketMetadata(address market) returns (string)  // Metadata URI for a market
```

**`MarketInfo` struct:**
```
struct MarketInfo {
    uint    marketId;
    address market;
    address creator;
    string  metadataURI;
    uint    createdAt;
}
```

---

### Step 3: Get Price Quotes

**Contract:** `PredictionMarket` (individual market address)

Before buying, query the cost:

```
market.quoteBuyYes(uint amountShares) returns (uint costInUSDC)
market.quoteBuyNo(uint amountShares) returns (uint costInUSDC)
```

- `amountShares` is in 1e18 scale (e.g., `1e18` = 1 share, `5e18` = 5 shares).
- Returns the USDC cost (6 decimals) to buy that many shares at the current state.
- These are view functions — they cost no gas.

**Reading current market state:**
```
market.yesShares() returns (uint)       // Total YES shares outstanding
market.noShares() returns (uint)        // Total NO shares outstanding
market.b() returns (uint)              // LMSR liquidity parameter
market.marketState() returns (uint8)   // 0=OPEN, 1=CLOSED, 2=RESOLVED
market.tradingDeadline() returns (uint) // Unix timestamp
market.resolveTime() returns (uint)     // Unix timestamp
market.oracle() returns (address)
market.creator() returns (address)
market.paused() returns (bool)
market.resolvedOutcome() returns (uint8) // 0=unresolved, 1=YES, 2=NO
market.userYes(address) returns (uint)  // YES shares held by an address
market.userNo(address) returns (uint)   // NO shares held by an address
market.collateralToken() returns (address) // USDC address
```

---

### Step 4: Buy Shares

**Contract:** `PredictionMarket`

1. **Get a quote** (see Step 3).
2. **Approve the market** to spend your USDC:

```
USDC.approve(marketAddress, quotedCost)
```

3. **Buy shares:**

```
market.buyYes(uint amountShares)   // Buy YES shares
market.buyNo(uint amountShares)    // Buy NO shares
```

- Pulls USDC from caller equal to the LMSR-computed cost.
- Increments `yesShares`/`noShares` global totals and `userYes[msg.sender]`/`userNo[msg.sender]`.
- Emits `SharesBought(address user, bool isYes, uint shares, uint cost)`.

**Requirements:** Market must be `OPEN`, not `paused`, and `block.timestamp < tradingDeadline`.

---

### Step 5: Sell Shares

**Contract:** `PredictionMarket`

```
market.sellYes(uint amountShares)  // Sell YES shares back to the market
market.sellNo(uint amountShares)   // Sell NO shares back to the market
```

- Computes the LMSR refund and transfers USDC back to the caller.
- Decrements share balances.
- Emits `SharesSold(address user, bool isYes, uint shares, uint refund)`.

**Requirements:** Caller must hold `>= amountShares`. Market must be `OPEN`, not `paused`, `block.timestamp < tradingDeadline`.

---

### Step 6: Transfer Shares

**Contract:** `PredictionMarket`

```
market.transferYesShares(address to, uint amount)
market.transferNoShares(address to, uint amount)
```

- Transfers shares between addresses (no USDC movement).
- Can be called at any time (even after market closes), as long as caller has sufficient shares.
- Emits `SharesTransferred(address from, address to, bool isYes, uint shares)`.

---

### Step 7: Close the Market

**Contract:** `PredictionMarket`

```
market.closeMarket()
```

- Callable by **anyone** after `block.timestamp >= tradingDeadline`.
- Sets `marketState` to `CLOSED`.
- Emits `MarketClosed()`.

> Note: If the oracle calls `resolve()` while the market is still `OPEN`, it auto-closes first.

---

### Step 8: Resolve the Market (Oracle Only)

**Contract:** `PredictionMarket`

```
market.resolve(uint8 outcome)   // 1 = YES wins, 2 = NO wins
```

- Callable **only by the oracle** address set during initialization.
- Requires `block.timestamp >= resolveTime`.
- Sets `resolvedOutcome` and `marketState` to `RESOLVED`.
- If market was still `OPEN`, auto-closes it first.
- Emits `MarketResolved(uint8 outcome)`.

---

### Step 9: Redeem Winnings

**Contract:** `PredictionMarket`

```
market.redeem()
```

- Callable after market is `RESOLVED`.
- If `resolvedOutcome == 1` (YES won): payout = caller's YES share balance.
- If `resolvedOutcome == 2` (NO won): payout = caller's NO share balance.
- Zeroes the caller's winning share balance and transfers USDC.
- Emits `Redeemed(address user, uint payout)`.

> **Important:** The payout is in the raw share units. The LMSR math ensures the market contract holds enough USDC to pay all winners.

---

## Emergency Controls

The **oracle** can pause and unpause trading:

```
market.pause()    // Blocks all buyYes/buyNo/sellYes/sellNo
market.unpause()  // Resumes trading
```

While paused, `closeMarket()`, `resolve()`, `redeem()`, and share transfers still work.

---

## LMSR Pricing Math

The protocol uses the **Logarithmic Market Scoring Rule (LMSR)** for automated market making. All math is computed on-chain using PRBMath `SD59x18` signed 59.18 fixed-point arithmetic.

### Cost Function

$$C(q_{YES}, q_{NO}) = b \cdot \ln\left(e^{q_{YES}/b} + e^{q_{NO}/b}\right)$$

Where:
- $q_{YES}$ = total YES shares outstanding (1e18 scale)
- $q_{NO}$ = total NO shares outstanding (1e18 scale)
- $b$ = liquidity parameter (1e18 scale)

### Buying Cost

To buy $\Delta$ YES shares:

$$\text{cost} = C(q_{YES} + \Delta,\ q_{NO}) - C(q_{YES},\ q_{NO})$$

To buy $\Delta$ NO shares:

$$\text{cost} = C(q_{YES},\ q_{NO} + \Delta) - C(q_{YES},\ q_{NO})$$

### Selling Refund

To sell $\Delta$ YES shares:

$$\text{refund} = C(q_{YES},\ q_{NO}) - C(q_{YES} - \Delta,\ q_{NO})$$

### Implied Probabilities

The LMSR produces real-time implied probabilities:

$$P(YES) = \frac{e^{q_{YES}/b}}{e^{q_{YES}/b} + e^{q_{NO}/b}}$$

$$P(NO) = \frac{e^{q_{NO}/b}}{e^{q_{YES}/b} + e^{q_{NO}/b}}$$

When $q_{YES} = q_{NO}$ (e.g. right after creation with balanced seeding), both probabilities are **50%**.

### Log-Sum-Exp Trick (Overflow Prevention)

The on-chain implementation avoids `exp()` overflow by using the log-sum-exp trick:

$$C = b \cdot \left(m + \ln\left(e^{a - m} + e^{c - m}\right)\right)$$

Where $a = q_{YES}/b$, $c = q_{NO}/b$, $m = \max(a, c)$. This ensures one exponent is always $e^0 = 1$.

### Effect of `b` (Liquidity Parameter)

- **Higher `b`:** More liquidity, prices change slowly, market maker subsidizes more. Max loss = $b \cdot \ln(2)$.
- **Lower `b`:** Less liquidity, prices move sharply with each trade, lower subsidy.
- Typical value: `1e18` (1.0 in fixed-point).

---

## Complete Function Reference

### PredictionMarket

| Function | Signature | Access | Description |
| -------- | --------- | ------ | ----------- |
| `initialize` | `initialize(address _collateral, address _oracle, address _creator, uint _tradingDeadline, uint _resolveTime, uint _b)` | External, once | Initializes a cloned market. Called by factory during creation. |
| `quoteBuyYes` | `quoteBuyYes(uint amountShares) → uint` | View | Returns USDC cost to buy given YES shares at current state. |
| `quoteBuyNo` | `quoteBuyNo(uint amountShares) → uint` | View | Returns USDC cost to buy given NO shares at current state. |
| `buyYes` | `buyYes(uint amountShares)` | External | Buy YES shares. Requires OPEN, not paused, before deadline. Pulls USDC. |
| `buyNo` | `buyNo(uint amountShares)` | External | Buy NO shares. Requires OPEN, not paused, before deadline. Pulls USDC. |
| `sellYes` | `sellYes(uint amountShares)` | External | Sell YES shares back. Requires OPEN, not paused, before deadline. Sends USDC refund. |
| `sellNo` | `sellNo(uint amountShares)` | External | Sell NO shares back. Requires OPEN, not paused, before deadline. Sends USDC refund. |
| `closeMarket` | `closeMarket()` | External, anyone | Close market after `tradingDeadline`. Sets state to CLOSED. |
| `resolve` | `resolve(uint8 outcome)` | External, oracle only | Resolve market after `resolveTime`. Outcome: `1`=YES, `2`=NO. Auto-closes if still OPEN. |
| `redeem` | `redeem()` | External | Claim USDC payout after resolution. Winners only. |
| `transferYesShares` | `transferYesShares(address _to, uint _amount)` | External | Transfer YES shares to another address. |
| `transferNoShares` | `transferNoShares(address _to, uint _amount)` | External | Transfer NO shares to another address. |
| `pause` | `pause()` | External, oracle only | Pause all trading. |
| `unpause` | `unpause()` | External, oracle only | Resume trading. |

**Public state variable getters (auto-generated):**

| Getter | Returns | Description |
| ------ | ------- | ----------- |
| `collateralToken()` | `address` | USDC token address |
| `oracle()` | `address` | Oracle authorized to resolve |
| `creator()` | `address` | Market creator address |
| `tradingDeadline()` | `uint` | Unix timestamp — trading stops |
| `resolveTime()` | `uint` | Unix timestamp — resolution allowed |
| `b()` | `uint` | LMSR liquidity parameter (1e18 scale) |
| `initialized()` | `bool` | Whether `initialize()` has been called |
| `marketState()` | `MarketState (uint8)` | `0`=OPEN, `1`=CLOSED, `2`=RESOLVED |
| `resolvedOutcome()` | `uint8` | `0`=unresolved, `1`=YES won, `2`=NO won |
| `paused()` | `bool` | Whether trading is paused |
| `yesShares()` | `uint` | Total YES shares outstanding |
| `noShares()` | `uint` | Total NO shares outstanding |
| `userYes(address)` | `uint` | YES shares held by given address |
| `userNo(address)` | `uint` | NO shares held by given address |

---

### PredictionMarketFactory

| Function | Signature | Access | Description |
| -------- | --------- | ------ | ----------- |
| `createMarket` | `createMarket(address _oracle, uint _tradingDeadline, uint _resolveTime, uint _b, string _metadataUri) → address` | External | Deploy a new market clone. Collects fee, seeds liquidity, stores metadata. Returns market address. |
| `updateMetadataURI` | `updateMetadataURI(address _market, string _newUri)` | External, creator only | Update off-chain metadata URI for a market. |
| `getMarket` | `getMarket(uint _id) → address` | View | Get market address by sequential ID. |
| `getMarketInfo` | `getMarketInfo(uint _id) → MarketInfo` | View | Get full MarketInfo struct by ID. |
| `getMarketMetadata` | `getMarketMetadata(address _market) → string` | View | Get metadata URI for a market address. |
| `getMarketCount` | `getMarketCount() → uint` | View | Total number of markets created. |
| `getAllMarkets` | `getAllMarkets() → address[]` | View | Array of all market addresses. |
| `setCreationFee` | `setCreationFee(uint _newFee)` | External, owner only | Update creation fee. Must be ≤ `MAX_CREATION_FEE` and ≥ `initialLiquidity`. |
| `setInitialLiquidity` | `setInitialLiquidity(uint _newAmount)` | External, owner only | Update initial liquidity. Must be ≤ `creationFee`. |
| `withdrawFees` | `withdrawFees(address _to, uint _amount)` | External, owner only | Withdraw accumulated protocol fees (USDC). |
| `transferOwnership` | `transferOwnership(address _newOwner)` | External, owner only | Transfer factory ownership. |

**Immutable / constant getters:**

| Getter | Returns | Description |
| ------ | ------- | ----------- |
| `COLLATERAL_TOKEN()` | `address` | USDC token address (immutable) |
| `IMPLEMENTATION()` | `address` | PredictionMarket implementation used for clones (immutable) |
| `MAX_CREATION_FEE()` | `uint` | `1000e6` — hard cap on fee (constant) |

**Public state variable getters:**

| Getter | Returns | Description |
| ------ | ------- | ----------- |
| `owner()` | `address` | Factory owner |
| `creationFee()` | `uint` | Current creation fee in USDC |
| `initialLiquidity()` | `uint` | Current initial liquidity amount |
| `marketCount()` | `uint` | Total markets deployed |
| `markets(uint)` | `MarketInfo` | Market info by ID |
| `marketInfoByAddress(address)` | `MarketInfo` | Market info by address |
| `allMarkets(uint)` | `address` | Market address by array index |

---

### MockUSDC (Testnet Only)

| Function | Signature | Access | Description |
| -------- | --------- | ------ | ----------- |
| `faucet` | `faucet()` | External, anyone | Mint 1,000 USDC (1,000e6) to `msg.sender`. |
| `mint` | `mint(address to, uint amount)` | External, owner only | Mint arbitrary amount to any address. |
| `transfer` | `transfer(address to, uint amount) → bool` | External | Standard ERC-20 transfer. |
| `approve` | `approve(address spender, uint amount) → bool` | External | Standard ERC-20 approve. |
| `transferFrom` | `transferFrom(address from, address to, uint amount) → bool` | External | Standard ERC-20 transferFrom. Supports infinite approval (`type(uint).max`). |
| `balanceOf` | `balanceOf(address) → uint` | View | Token balance. |
| `allowance` | `allowance(address owner, address spender) → uint` | View | Spending allowance. |
| `decimals` | `decimals() → uint8` | Pure | Returns `6`. |
| `name` | `name() → string` | Pure | Returns `"USD Coin (Mock)"`. |
| `symbol` | `symbol() → string` | Pure | Returns `"USDC"`. |
| `transferOwnership` | `transferOwnership(address newOwner)` | External, owner only | Transfer mock token ownership. |

---

## Metadata URI Format

Each market stores a `metadataURI` pointing to a JSON document. Recommended schema:

```json
{
  "title": "Will Acme Corp hit $10k MRR by March 2026?",
  "description": "Prediction on whether Acme Corp reaches $10,000 monthly recurring revenue.",
  "category": "business",
  "outcomes": ["YES", "NO"],
  "resolution_source": "https://acme.example.com/metrics",
  "creator_info": {
    "name": "Acme Corp",
    "website": "https://acme.example.com"
  },
  "tags": ["revenue", "startup", "saas"]
}
```

---

## Events Reference

### PredictionMarket Events

| Event | Parameters | Emitted When |
| ----- | ---------- | ------------ |
| `SharesBought` | `address indexed user, bool indexed isYes, uint shares, uint cost` | User buys YES or NO shares |
| `SharesSold` | `address indexed user, bool indexed isYes, uint shares, uint refund` | User sells shares back |
| `SharesTransferred` | `address indexed from, address indexed to, bool indexed isYes, uint shares` | Shares transferred between users |
| `MarketClosed` | _(none)_ | Market transitions to CLOSED |
| `MarketResolved` | `uint8 outcome` | Oracle resolves market (1=YES, 2=NO) |
| `MarketPaused` | _(none)_ | Oracle pauses trading |
| `MarketUnpaused` | _(none)_ | Oracle unpauses trading |
| `Redeemed` | `address indexed user, uint payout` | Winner claims USDC payout |

### PredictionMarketFactory Events

| Event | Parameters | Emitted When |
| ----- | ---------- | ------------ |
| `MarketCreated` | `uint indexed marketId, address indexed market, address indexed creator, address oracle, uint tradingDeadline, uint resolveTime, uint liquidityParam, uint initialLiquidity, string metadataURI` | New market deployed |
| `MetadataUpdated` | `address indexed market, string newURI` | Creator updates metadata |
| `CreationFeeUpdated` | `uint oldFee, uint newFee` | Owner changes creation fee |
| `InitialLiquidityUpdated` | `uint oldAmount, uint newAmount` | Owner changes initial liquidity |
| `FeesWithdrawn` | `address indexed to, uint amount` | Owner withdraws protocol fees |
| `OwnershipTransferred` | `address indexed previousOwner, address indexed newOwner` | Ownership transferred |

---

## Quick Reference: AI Agent Cheatsheet

### Create a market (full sequence)

```
1. USDC.faucet()                                          // testnet only — get 1000 USDC
2. USDC.approve(factory, 10000000)                        // approve 10 USDC fee
3. factory.createMarket(oracle, deadline, resolveTime, 1000000000000000000, "ipfs://...")
   → returns marketAddress
```

### Buy shares on a market

```
1. cost = market.quoteBuyYes(1000000000000000000)         // quote 1 YES share
2. USDC.approve(marketAddress, cost)
3. market.buyYes(1000000000000000000)                     // buy 1 YES share
```

### Sell shares

```
1. market.sellYes(1000000000000000000)                    // sell 1 YES share, receive USDC refund
```

### Check position

```
market.userYes(myAddress)   → my YES share balance
market.userNo(myAddress)    → my NO share balance
```

### After resolution

```
1. market.resolvedOutcome()  → 1 (YES won) or 2 (NO won)
2. market.redeem()           → receive USDC payout
```

### Discover all markets

```
1. count = factory.getMarketCount()
2. for i in 0..count-1:
     info = factory.getMarketInfo(i)
     // info.market, info.creator, info.metadataURI, info.createdAt
```

---

## Scale & Units Summary

| Value Type    | Scale / Decimals | Example                                   |
| ------------- | ---------------- | ----------------------------------------- |
| USDC amounts  | 6 decimals       | `10000000` = $10.00, `1000000` = $1.00    |
| Share amounts  | 18 decimals (1e18) | `1000000000000000000` = 1 share          |
| `b` parameter | 18 decimals (1e18) | `1000000000000000000` = 1.0              |
| Timestamps    | Unix seconds     | `1738972800` = Feb 8 2025 00:00:00 UTC    |

---

## Dependencies

| Library | Purpose | Remapping |
| ------- | ------- | --------- |
| `forge-std` | Foundry testing & scripting | _(default)_ |
| `prb-math` v4 | `SD59x18` signed fixed-point math for LMSR | `@prb/math/=lib/prb-math/src/` |
| `openzeppelin-contracts` | `Clones` (EIP-1167 minimal proxies) | `@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/` |
