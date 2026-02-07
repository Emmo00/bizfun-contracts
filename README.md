# BizFun Contracts

> **Let AI Agents Fund Your Business, Idea, Project, StartUp, Career**

BizFun is a prediction-market protocol powered by the **$BizMart** AI agent. It lets businesses, startups, raw ideas, and personal brands launch on-chain prediction markets around measurable real-world outcomes — then lets AI agents and humans trade, debate, and speculate on whether those goals will be met.

These contracts are the on-chain backbone: a **factory** that deploys individual prediction markets, collects a creation fee in USDC, seeds initial liquidity, and links each market to off-chain metadata (questions, business details, social links, etc.).

---

## Architecture

```
┌──────────────────────────────┐
│   PredictionMarketFactory    │  ← Singleton, deploys & tracks all markets
│  ─────────────────────────── │
│  • createMarket()            │  ← Collects USDC fee, deploys market, seeds liquidity
│  • updateMetadataURI()       │  ← Creator updates off-chain metadata link
│  • setCreationFee()          │  ← Owner admin
│  • setInitialLiquidity()     │  ← Owner admin
│  • withdrawFees()            │  ← Owner withdraws protocol revenue
│  • getMarket / getAllMarkets │  ← View helpers
└──────────┬───────────────────┘
           │ deploys via `new`
           ▼
┌──────────────────────────────┐
│      PredictionMarket        │  ← One per question / business prediction
│  ─────────────────────────── │
│  • buyYes() / buyNo()        │  ← LMSR automated market maker
│  • sellYes() / sellNo()      │
│  • quoteBuyYes/No()          │  ← View: get cost before trading
│  • closeMarket()             │  ← Anyone, after tradingDeadline
│  • resolve(outcome)          │  ← Oracle only, after resolveTime
│  • redeem()                  │  ← Winners claim USDC payout
└──────────────────────────────┘
```

### Key design decisions

| Decision | Rationale |
|----------|-----------|
| **Single global USDC collateral** | Matches the BizFun product — all markets denominated in USDC |
| **`new` deployment (not clones)** | Keeps `immutable` fields for gas-efficient reads; contract size is small enough that deploy cost is acceptable |
| **LMSR pricing** | Logarithmic Market Scoring Rule ensures bounded loss for the liquidity provider and continuous pricing at any volume |
| **Off-chain metadata via URI** | Stores an IPFS/Arweave/HTTPS link per market pointing to a JSON blob — keeps gas low and metadata flexible |
| **Initial liquidity seeding** | Part of the creation fee is used to buy balanced YES/NO shares, bootstrapping the market at ~50/50 probability |

---

## Contracts

| File | Description |
|------|-------------|
| `src/PredictionMarketFactory.sol` | Factory — deploys markets, stores metadata, collects fees, admin controls |
| `src/PredictionMarket.sol` | Individual prediction market with LMSR AMM, lifecycle management, and redemption |
| `src/interfaces/IERC20.sol` | Minimal ERC-20 interface shared by both contracts |
| `script/DeployFactory.s.sol` | Foundry deployment script for the factory |
| `test/PredictionMarket.t.sol` | Full test suite (42 tests) |

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
2. Deploys a new `PredictionMarket` contract
3. Seeds initial balanced liquidity (splits fee portion 50/50 into YES and NO shares)
4. Stores the market info and metadata URI on-chain
5. Emits a `MarketCreated` event

### 2. Trading

Anyone can call `buyYes()`, `buyNo()`, `sellYes()`, or `sellNo()` on a market before its trading deadline. Prices are determined by the **LMSR cost function** — the more shares of one outcome that exist, the higher the price to buy more of that outcome.

Use `quoteBuyYes(amount)` and `quoteBuyNo(amount)` to preview costs before trading.

### 3. Resolution & redemption

1. After the trading deadline, anyone can call `closeMarket()` to prevent further trades
2. After the resolve time, the **oracle** calls `resolve(1)` (YES wins) or `resolve(2)` (NO wins)
3. Winners call `redeem()` to claim their USDC payout

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

### Deploy

```shell
USDC_ADDRESS=0x... forge script script/DeployFactory.s.sol:DeployFactory \
  --rpc-url <your_rpc_url> \
  --private-key <your_private_key> \
  --broadcast
```

Optional env vars for deployment:
- `USDC_ADDRESS` — **(required)** address of the USDC token contract
- `CREATION_FEE` — total fee in USDC raw units (default: `10000000` = $10)
- `INITIAL_LIQUIDITY` — portion of fee seeded into new markets (default: `5000000` = $5)

### Format

```shell
forge fmt
```

---

## License

MIT
