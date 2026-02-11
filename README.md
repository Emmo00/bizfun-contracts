# BizFun Contracts

> **Let AI Agents Fund Your Business, Idea, Project, StartUp, Career**

BizFun is a prediction-market protocol powered by the **$BizMart** AI agent. It lets businesses, startups, raw ideas, and personal brands launch on-chain prediction markets around measurable real-world outcomes — then lets AI agents and humans trade, debate, and speculate on whether those goals will be met.

These contracts are the on-chain backbone: a **factory** that deploys individual prediction markets via **EIP-1167 minimal proxies (clones)**, collects a creation fee in USDC, seeds initial liquidity, and links each market to off-chain metadata (questions, business details, social links, etc.).

---


## Deployments

### Base Sepolia (Testnet) — Chain ID `84532`

| Contract                              | Address                                      | Notes                                             |
| ------------------------------------- | ------- | ------------------ |
| **MockUSDC**                          | [`0x0d0ec10cc2eaeb6dbc9127fb98c9ebbfc029b8c9`](https://sepolia.basescan.org/address/0x0d0ec10cc2eaeb6dbc9127fb98c9ebbfc029b8c9) | ERC-20, 6 decimals, has `faucet()`                |
| **PredictionMarket (implementation)** | [`0xc4556812D9bEB0b402f03CaF57870628F51bD1DA`](https://sepolia.basescan.org/address/0xc4556812D9bEB0b402f03CaF57870628F51bD1DA) | Do NOT interact directly — clone template only    |
| **PredictionMarketFactory**           | [`0x59c474cA3bBFe4017813D9C432E3066F63dfAEad`](https://sepolia.basescan.org/address/0x59c474cA3bBFe4017813D9C432E3066F63dfAEad) | Entry point for creating and discovering markets  |

> **Collateral token:** USDC (6 decimals). On testnet the MockUSDC above is used. Call `faucet()` on MockUSDC to mint 1,000 USDC to your address for free.

### Base Mainnet — Chain ID `8453`

| Contract                              | Address | Notes              |
| ------------------------------------- | ------- | ------------------ |
| **USDC**                              | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) | Native USDC on Base |
| **PredictionMarket (implementation)** | [`0x734de9628bF15f14C888b43E588bB63440887247`](https://basescan.org/address/0x734de9628bF15f14C888b43E588bB63440887247) | Clone template     |
| **PredictionMarketFactory**           | [`0xADBeAF3b2C610fa71003660605087341779f2EE9`](https://basescan.org/address/0xADBeAF3b2C610fa71003660605087341779f2EE9) | Entry point        |

### BNB Smart Chain (BSC) — Chain ID `56`

| Contract                              | Address | Notes          |
| ------------------------------------- | ------- | -------------- |
| **USDC**                              | [`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`](https://bscscan.com/address/0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d) | USDC on BSC    |
| **PredictionMarket (implementation)** | [`0x734de9628bF15f14C888b43E588bB63440887247`](https://bscscan.com/address/0x734de9628bF15f14C888b43E588bB63440887247) | Clone template |
| **PredictionMarketFactory**           | [`0xADBeAF3b2C610fa71003660605087341779f2EE9`](https://bscscan.com/address/0xADBeAF3b2C610fa71003660605087341779f2EE9) | Entry point    |

### Monad Mainnet - Chain ID `143`

| Contract                              | Address | Notes          |
| Contract                              | Address | Notes          |
| ------------------------------------- | ------- | -------------- |
| **USDC**                              | [`0x754704Bc059F8C67012fEd69BC8A327a5aafb603`](https://monadVision.com/address/0x754704Bc059F8C67012fEd69BC8A327a5aafb603) | USDC on Monad    |
| **PredictionMarket (implementation)** | [`0x734de9628bF15f14C888b43E588bB63440887247`](https://monadVision.com/address/0x734de9628bF15f14C888b43E588bB63440887247) | Clone template |
| **PredictionMarketFactory**           | [`0xADBeAF3b2C610fa71003660605087341779f2EE9`](https://monadVision.com/address/0xADBeAF3b2C610fa71003660605087341779f2EE9) | Entry point    |

---


## Architecture

```
┌──────────────────────────────┐
│   PredictionMarketFactory    │  ← Singleton, deploys & tracks all markets
│  ─────────────────────────── │
│  • createMarket()            │  ← Collects USDC fee, clones market, seeds liquidity
│  • updateMetadataURI()       │  ← Creator updates off-chain metadata link
│  • setCreationFee()          │  ← Owner admin (capped at $1000 USDC)
│  • setInitialLiquidity()     │  ← Owner admin
│  • withdrawFees()            │  ← Owner withdraws protocol revenue
│  • getMarket / getAllMarkets │  ← View helpers
└──────────┬───────────────────┘
           │ deploys via EIP-1167 clone
           ▼
┌──────────────────────────────┐
│     PredictionMarket (impl)  │  ← Logic contract, cloned per market
│  ─────────────────────────── │
│  • initialize()              │  ← One-time setup (called by factory)
│  • buyYes() / buyNo()        │  ← LMSR automated market maker
│  • sellYes() / sellNo()      │
│  • quoteBuyYes/No()          │  ← View: get cost before trading
│  • transferYesShares()       │  ← Transfer shares to another address
│  • transferNoShares()        │
│  • closeMarket()             │  ← Anyone, after tradingDeadline
│  • resolve(outcome)          │  ← Oracle only, after resolveTime (auto-closes)
│  • redeem()                  │  ← Winners claim USDC payout
│  • pause() / unpause()       │  ← Oracle emergency controls
└──────────────────────────────┘
```

### Key design decisions

| Decision | Rationale |
|----------|-----------|
| **Single global USDC collateral** | Matches the BizFun product — all markets denominated in USDC |
| **EIP-1167 minimal proxy (clones)** | One logic contract deployed once; each market is a ~45-byte proxy. Keeps factory well under the 24 KB EVM size limit and slashes deployment gas by ~5× |
| **LMSR pricing (PRBMath SD59x18)** | Logarithmic Market Scoring Rule ensures bounded loss for the liquidity provider and continuous pricing at any volume. Uses production-grade fixed-point math via [PRBMath v4](https://github.com/PaulRBerg/prb-math) with a log-sum-exp trick to avoid overflow |
| **Off-chain metadata via URI** | Stores an IPFS/Arweave/HTTPS link per market pointing to a JSON blob — keeps gas low and metadata flexible |
| **Initial liquidity seeding** | Part of the creation fee buys balanced YES/NO shares, bootstrapping the market at ~50/50 probability. Shares are transferred to the creator |
| **CEI pattern** | All state updates happen before external calls in `createMarket()` to prevent reentrancy |
| **Emergency pause** | Oracle can pause/unpause trading on any market without resolving it |
| **Max fee cap** | Creation fee is capped at 1,000 USDC (`MAX_CREATION_FEE`) to protect users from admin abuse |

---

## Contracts

| File | Description |
|------|-------------|
| `src/PredictionMarketFactory.sol` | Factory — clones markets, stores metadata, collects fees, admin controls |
| `src/PredictionMarket.sol` | Individual prediction market with LMSR AMM, lifecycle management, share transfers, emergency pause, and redemption |
| `src/interfaces/IERC20.sol` | Minimal ERC-20 interface shared by both contracts |
| `src/mocks/MockUSDC.sol` | Testnet-deployable ERC-20 mock of USDC with a public `faucet()` |
| `script/DeployFactory.s.sol` | Foundry deployment script — deploys implementation + factory |
| `script/DeployMockUSDC.s.sol` | Foundry deployment script — deploys MockUSDC for testnet |
| `test/PredictionMarket.t.sol` | Full test suite (55 tests) |

---

## How it works

### 1. Market creation

A user (guided by **$BizMart**) calls `factory.createMarket(...)` with:

- **Oracle address** — the trusted address that will resolve the outcome
- **Trading deadline** — timestamp after which no more trades are allowed
- **Resolve time** — timestamp after which the oracle can declare the outcome
- **Liquidity parameter (b)** — controls LMSR price sensitivity
- **Metadata URI** — link to a JSON blob with the prediction question, business details, images, etc.

The factory:
1. Collects the creation fee in USDC from the caller
2. Clones the `PredictionMarket` implementation and calls `initialize()`
3. Seeds initial balanced liquidity (splits fee portion 50/50 into YES and NO shares)
4. Transfers the liquidity shares to the market creator
5. Stores the market info and metadata URI on-chain
6. Emits a `MarketCreated` event

### 2. Trading

Anyone can call `buyYes()`, `buyNo()`, `sellYes()`, or `sellNo()` on a market before its trading deadline. Prices are determined by the **LMSR cost function** — the more shares of one outcome that exist, the higher the price to buy more of that outcome.

Use `quoteBuyYes(amount)` and `quoteBuyNo(amount)` to preview costs before trading.

Shareholders can transfer their position to another address via `transferYesShares()` and `transferNoShares()`.

### 3. Resolution & redemption

1. After the trading deadline, anyone can call `closeMarket()` to prevent further trades
2. After the resolve time, the **oracle** calls `resolve(1)` (YES wins) or `resolve(2)` (NO wins) — this auto-closes the market if still open
3. Winners call `redeem()` to claim their USDC payout

### 4. Emergency controls

The oracle can call `pause()` to halt all trading on a market without resolving it, and `unpause()` to resume. This is intended for situations where the oracle detects manipulation or needs to investigate.

### Metadata URI format

The `metadataURI` should point to a JSON file with a structure like:

```json
{
  "question": "Will this business make $3,000 in the next 30 days?",
  "businessName": "Acme Widget Co",
  "description": "Acme sells handcrafted widgets to enterprise customers...",
  "category": "e-commerce",
  "imageUrl": "ipfs://Qm...",
  "socialLinks": {
    "twitter": "https://x.com/acmewidgets",
    "website": "https://acmewidgets.com"
  }
}
```

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [forge-std](https://github.com/foundry-rs/forge-std) | latest | Foundry testing & scripting |
| [prb-math](https://github.com/PaulRBerg/prb-math) | v4 | Production-grade SD59x18 fixed-point math for LMSR |
| [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | latest | `Clones` library for EIP-1167 minimal proxies |

---

## Development

Built with [Foundry](https://book.getfoundry.sh/).

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Test (verbose)

```shell
forge test -vvv
```

### Check contract sizes

```shell
forge build --sizes
```

### Deploy (testnet)

```shell
# 1. Deploy MockUSDC (testnet only)
source .env
forge script script/DeployMockUSDC.s.sol:DeployMockUSDC \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast -vvvv

# 2. Set USDC_ADDRESS in .env to the deployed MockUSDC address

# 3. Deploy implementation + factory
forge script script/DeployFactory.s.sol:DeployFactory \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### Deploy (mainnet)

```shell
source .env
forge script script/DeployFactory.s.sol:DeployFactory \
  --rpc-url $BASE_RPC_URL \
  --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PRIVATE_KEY` | ✅ | — | Deployer wallet private key |
| `USDC_ADDRESS` | ✅ | — | Address of the USDC token contract |
| `CREATION_FEE` | ❌ | `10000000` ($10) | Total fee in USDC raw units |
| `INITIAL_LIQUIDITY` | ❌ | `5000000` ($5) | Portion of fee seeded into new markets |
| `ETHERSCAN_API_KEY` | ❌ | — | For contract verification on block explorers |

### Format

```shell
forge fmt
```

---

## Deployed Addresses

### Base Sepolia (testnet)

| Contract | Address |
|----------|---------|
| MockUSDC | `0x0d0ec10Cc2eaeb6DBc9127fb98c9EBbFC029B8C9` |
| PredictionMarket (impl) | _deployed with factory script_ |
| PredictionMarketFactory | _deployed with factory script_ |

---

## License

MIT
