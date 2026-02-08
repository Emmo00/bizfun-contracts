// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title PredictionMarketFactory
/// @notice Factory contract for deploying BizFun prediction markets.
///         Uses EIP-1167 minimal proxies (clones) to keep deployment costs low
///         and factory bytecode well under the 24 KB EVM limit.
///         Collects a creation fee in USDC, deploys a new PredictionMarket clone,
///         seeds initial liquidity, and stores off-chain metadata URIs.
contract PredictionMarketFactory {
    // ---------------- STRUCTS ----------------

    struct MarketInfo {
        uint    marketId;       // sequential market id
        address market;         // deployed PredictionMarket address
        address creator;        // who created the market
        string  metadataURI;    // IPFS / Arweave / HTTPS link to off-chain JSON metadata
        uint    createdAt;      // block.timestamp at creation
    }

    // ---------------- EVENTS ----------------

    event MarketCreated(
        uint indexed marketId,
        address indexed market,
        address indexed creator,
        address oracle,
        uint tradingDeadline,
        uint resolveTime,
        uint liquidityParam,
        uint initialLiquidity,
        string metadataURI
    );

    event MetadataUpdated(address indexed market, string newURI);
    event CreationFeeUpdated(uint oldFee, uint newFee);
    event InitialLiquidityUpdated(uint oldAmount, uint newAmount);
    event FeesWithdrawn(address indexed to, uint amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------- STATE ----------------

    IERC20 public immutable COLLATERAL_TOKEN; // USDC (single global token)
    address public immutable IMPLEMENTATION;   // PredictionMarket logic contract

    uint public constant COLLATERAL_DECIMALS = 6;   // USDC decimals
    uint public constant MAX_CREATION_FEE = 1000e6;  // $1000 USDC cap

    address public owner;
    uint public creationFee;        // total fee charged to creator (in USDC, 6-decimal)
    uint public initialLiquidity;   // portion of fee sent to seed the new market

    uint public marketCount;
    mapping(uint => MarketInfo) public markets;
    mapping(address => MarketInfo) public marketInfoByAddress;
    address[] public allMarkets;

    // ---------------- MODIFIERS ----------------

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "Not owner");
    }

    // ---------------- CONSTRUCTOR ----------------

    /// @param _collateralToken  Address of the USDC token contract.
    /// @param _implementation   Address of the deployed PredictionMarket logic contract (used as clone template).
    /// @param _creationFee      Total fee in USDC (e.g. 10e6 for $10 USDC).
    /// @param _initialLiquidity Portion of fee forwarded to seed the market (must be <= _creationFee).
    constructor(
        address _collateralToken,
        address _implementation,
        uint _creationFee,
        uint _initialLiquidity
    ) {
        require(_collateralToken != address(0), "Invalid token");
        require(_implementation != address(0), "Invalid implementation");
        require(_creationFee <= MAX_CREATION_FEE, "Fee exceeds max");
        require(_initialLiquidity <= _creationFee, "Liquidity > fee");

        COLLATERAL_TOKEN = IERC20(_collateralToken);
        IMPLEMENTATION = _implementation;
        owner = msg.sender;
        creationFee = _creationFee;
        initialLiquidity = _initialLiquidity;
    }

    // ---------------- MARKET CREATION ----------------

    /// @notice Deploy a new PredictionMarket and seed it with initial balanced liquidity.
    /// @dev    Caller must have approved this factory for at least `creationFee` of USDC.
    ///         The `metadataURI` should point to a JSON blob with fields such as:
    ///         { "question", "businessName", "description", "category", "imageUrl", "socialLinks", ... }
    /// @param _oracle           Address allowed to resolve the market.
    /// @param _tradingDeadline  Timestamp after which trading stops.
    /// @param _resolveTime      Timestamp after which the oracle can resolve.
    /// @param _b                LMSR liquidity parameter (scaled to 1e18).
    /// @param _metadataUri      Off-chain metadata URI (IPFS, Arweave, HTTPS).
    /// @return marketAddress    Address of the newly deployed PredictionMarket.
    function createMarket(
        address _oracle,
        uint _tradingDeadline,
        uint _resolveTime,
        uint _b,
        string calldata _metadataUri
    ) external returns (address) {
        require(_oracle != address(0), "Invalid oracle");
        require(_tradingDeadline > block.timestamp, "Deadline in past");
        require(_resolveTime >= _tradingDeadline, "Resolve before deadline");
        require(_b > 0, "Invalid liquidity param");
        require(bytes(_metadataUri).length > 0, "Empty metadata URI");

        // ----- Collect creation fee from caller -----
        if (creationFee > 0) {
            require(
                COLLATERAL_TOKEN.transferFrom(msg.sender, address(this), creationFee),
                "Fee transfer failed"
            );
        }

        // ----- Deploy new PredictionMarket clone (EIP-1167 minimal proxy) -----
        address marketAddress = Clones.clone(IMPLEMENTATION);
        PredictionMarket market = PredictionMarket(marketAddress);
        market.initialize(
            address(COLLATERAL_TOKEN),
            _oracle,
            msg.sender,        // creator
            _tradingDeadline,
            _resolveTime,
            _b,
            COLLATERAL_DECIMALS
        );

        // ----- Store market info BEFORE external calls (CEI pattern) -----
        uint id = marketCount;
        MarketInfo memory info = MarketInfo({
            marketId: id,
            market: marketAddress,
            creator: msg.sender,
            metadataURI: _metadataUri,
            createdAt: block.timestamp
        });
        markets[id] = info;
        marketInfoByAddress[marketAddress] = info;
        allMarkets.push(marketAddress);
        marketCount = id + 1;

        // ----- Seed initial balanced liquidity -----
        if (initialLiquidity > 0) {
            // Transfer USDC directly into the market contract.
            require(
                COLLATERAL_TOKEN.transfer(marketAddress, initialLiquidity),
                "Liquidity transfer failed"
            );

            // Record equal YES and NO shares under the creator.
            // LMSR identity: C(q, q) - C(0, 0) = q, so sharesPerSide = initialLiquidity * collateralScale
            // gives a total cost of exactly initialLiquidity USDC.
            // By using seedShares we skip the buy path entirely — no rounding, no
            // sequential-cost asymmetry.
            uint collateralScaleFactor = 10 ** (18 - COLLATERAL_DECIMALS);
            uint sharesPerSide = initialLiquidity * collateralScaleFactor;
            market.seedShares(msg.sender, sharesPerSide, sharesPerSide);
        }

        emit MarketCreated(
            id,
            marketAddress,
            msg.sender,
            _oracle,
            _tradingDeadline,
            _resolveTime,
            _b,
            initialLiquidity,
            _metadataUri
        );

        return marketAddress;
    }

    // ---------------- METADATA ----------------

    /// @notice Update the off-chain metadata URI for a market you created.
    /// @param _market   Address of the PredictionMarket.
    /// @param _newUri   New metadata URI.
    function updateMetadataURI(address _market, string calldata _newUri) external {
        MarketInfo storage info = marketInfoByAddress[_market];
        require(info.market != address(0), "Market not found");
        require(info.creator == msg.sender, "Not market creator");
        require(bytes(_newUri).length > 0, "Empty metadata URI");

        info.metadataURI = _newUri;

        // Direct update via stored marketId (no loop needed)
        markets[info.marketId].metadataURI = _newUri;

        emit MetadataUpdated(_market, _newUri);
    }

    // ---------------- VIEW HELPERS ----------------

    /// @notice Get the address of a market by its sequential id.
    function getMarket(uint _id) external view returns (address) {
        require(_id < marketCount, "Invalid market id");
        return markets[_id].market;
    }

    /// @notice Get full info for a market by its sequential id.
    function getMarketInfo(uint _id) external view returns (MarketInfo memory) {
        require(_id < marketCount, "Invalid market id");
        return markets[_id];
    }

    /// @notice Get the metadata URI for a deployed market address.
    function getMarketMetadata(address _market) external view returns (string memory) {
        MarketInfo storage info = marketInfoByAddress[_market];
        require(info.market != address(0), "Market not found");
        return info.metadataURI;
    }

    /// @notice Get the total number of deployed markets.
    function getMarketCount() external view returns (uint) {
        return marketCount;
    }

    /// @notice Get all deployed market addresses.
    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    // ---------------- ADMIN ----------------

    /// @notice Update the creation fee.
    function setCreationFee(uint _newFee) external onlyOwner {
        require(_newFee <= MAX_CREATION_FEE, "Fee exceeds max");
        require(_newFee >= initialLiquidity, "Fee < liquidity");
        uint oldFee = creationFee;
        creationFee = _newFee;
        emit CreationFeeUpdated(oldFee, _newFee);
    }

    /// @notice Update the initial liquidity amount seeded into new markets.
    function setInitialLiquidity(uint _newAmount) external onlyOwner {
        require(_newAmount <= creationFee, "Liquidity > fee");
        uint oldAmount = initialLiquidity;
        initialLiquidity = _newAmount;
        emit InitialLiquidityUpdated(oldAmount, _newAmount);
    }

    /// @notice Withdraw accumulated protocol fees (fee - initialLiquidity portion per market).
    function withdrawFees(address _to, uint _amount) external onlyOwner {
        require(_to != address(0), "Invalid address");
        uint balance = COLLATERAL_TOKEN.balanceOf(address(this));
        require(_amount <= balance, "Insufficient balance");

        require(COLLATERAL_TOKEN.transfer(_to, _amount), "Withdraw failed");

        emit FeesWithdrawn(_to, _amount);
    }

    /// @notice Transfer ownership of the factory.
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(oldOwner, _newOwner);
    }
}
