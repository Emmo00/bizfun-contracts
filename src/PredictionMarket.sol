// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {SD59x18, sd, unwrap} from "@prb/math/SD59x18.sol";

contract PredictionMarket {
    enum MarketState { OPEN, CLOSED, RESOLVED }

    // ---------------- EVENTS ----------------

    event SharesBought(address indexed user, bool indexed isYes, uint shares, uint cost);
    event SharesSold(address indexed user, bool indexed isYes, uint shares, uint refund);
    event SharesTransferred(address indexed from, address indexed to, bool indexed isYes, uint shares);
    event MarketClosed();
    event MarketResolved(uint8 outcome);
    event MarketPaused();
    event MarketUnpaused();
    event Redeemed(address indexed user, uint payout);

    // ---------------- STATE ----------------

    IERC20 public collateralToken; // USDC
    address public oracle;
    address public creator;
    uint public tradingDeadline;
    uint public resolveTime;
    uint public b; // liquidity parameter (scaled)

    bool public initialized;
    MarketState public marketState;
    uint8 public resolvedOutcome; // 1 = YES, 2 = NO
    bool public paused;

    uint public yesShares;
    uint public noShares;

    mapping(address => uint) public userYes;
    mapping(address => uint) public userNo;

    uint private constant ONE = 1e18; // fixed point scale

    /// @notice Initialize the market (used by clones instead of a constructor).
    ///         Can only be called once.
    function initialize(
        address _collateral,
        address _oracle,
        address _creator,
        uint _tradingDeadline,
        uint _resolveTime,
        uint _b
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;

        collateralToken = IERC20(_collateral);
        oracle = _oracle;
        creator = _creator;
        tradingDeadline = _tradingDeadline;
        resolveTime = _resolveTime;
        b = _b;
        marketState = MarketState.OPEN;
    }

    modifier onlyOracle() {
        _onlyOracle();
        _;
    }

    modifier onlyOpen() {
        _onlyOpen();
        _;
    }

    function _onlyOracle() internal view {
        require(msg.sender == oracle, "Not oracle");
    }

    function _onlyOpen() internal view {
        require(!paused, "Market paused");
        require(marketState == MarketState.OPEN, "Market not open");
        require(block.timestamp < tradingDeadline, "Trading ended");
    }

    // ---------------- LMSR MATH (PRBMath SD59x18) ----------------

    /// @dev LMSR cost function: C(qYes, qNo) = b * ln(exp(qYes/b) + exp(qNo/b))
    ///      Uses the log-sum-exp trick to avoid overflow:
    ///        C = b * (m + ln(exp(a - m) + exp(c - m)))
    ///      where a = qYes/b, c = qNo/b, m = max(a, c).
    ///      Since one of the exp terms is always exp(0) = 1, the ln argument is always >= 1.
    function _cost(uint qYes, uint qNo) internal view returns (uint) {
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 bFixed = sd(int256(b));
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 a = sd(int256(qYes)).div(bFixed);
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 c = sd(int256(qNo)).div(bFixed);

        // m = max(a, c)
        SD59x18 m = a.gt(c) ? a : c;

        // log-sum-exp: m + ln(exp(a - m) + exp(c - m))
        SD59x18 sumExp = (a.sub(m)).exp().add((c.sub(m)).exp());
        SD59x18 result = bFixed.mul(m.add(sumExp.ln()));

        int256 raw = unwrap(result);
        // forge-lint: disable-next-line(unsafe-typecast)
        return raw > 0 ? uint(raw) : 0;
    }

    /// @notice Returns the current cost to buy `amountShares` of YES shares.
    function quoteBuyYes(uint amountShares) external view returns (uint) {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares + amountShares, noShares);
        return costAfter - costBefore;
    }

    /// @notice Returns the current cost to buy `amountShares` of NO shares.
    function quoteBuyNo(uint amountShares) external view returns (uint) {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares + amountShares);
        return costAfter - costBefore;
    }

    // ---------------- TRADING ----------------

    function buyYes(uint amountShares) external onlyOpen {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares + amountShares, noShares);
        uint payment = costAfter - costBefore;

        yesShares += amountShares;
        userYes[msg.sender] += amountShares;

        require(collateralToken.transferFrom(msg.sender, address(this), payment), "Transfer failed");

        emit SharesBought(msg.sender, true, amountShares, payment);
    }

    function buyNo(uint amountShares) external onlyOpen {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares + amountShares);
        uint payment = costAfter - costBefore;

        noShares += amountShares;
        userNo[msg.sender] += amountShares;

        require(collateralToken.transferFrom(msg.sender, address(this), payment), "Transfer failed");

        emit SharesBought(msg.sender, false, amountShares, payment);
    }

    function sellYes(uint amountShares) external onlyOpen {
        require(userYes[msg.sender] >= amountShares, "Not enough YES");

        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares - amountShares, noShares);
        uint refund = costBefore - costAfter;

        yesShares -= amountShares;
        userYes[msg.sender] -= amountShares;

        require(collateralToken.transfer(msg.sender, refund), "Refund failed");

        emit SharesSold(msg.sender, true, amountShares, refund);
    }

    function sellNo(uint amountShares) external onlyOpen {
        require(userNo[msg.sender] >= amountShares, "Not enough NO");

        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares - amountShares);
        uint refund = costBefore - costAfter;

        noShares -= amountShares;
        userNo[msg.sender] -= amountShares;

        require(collateralToken.transfer(msg.sender, refund), "Refund failed");

        emit SharesSold(msg.sender, false, amountShares, refund);
    }

    // ---------------- LIFECYCLE ----------------

    function closeMarket() external {
        require(block.timestamp >= tradingDeadline, "Too early");
        require(marketState == MarketState.OPEN, "Already closed");
        marketState = MarketState.CLOSED;

        emit MarketClosed();
    }

    function resolve(uint8 outcome) external onlyOracle {
        require(block.timestamp >= resolveTime, "Too early");
        require(marketState != MarketState.RESOLVED, "Already resolved");
        require(outcome == 1 || outcome == 2, "Invalid outcome");

        // Auto-close if still OPEN (enforces OPEN → CLOSED → RESOLVED lifecycle)
        if (marketState == MarketState.OPEN) {
            marketState = MarketState.CLOSED;
            emit MarketClosed();
        }

        resolvedOutcome = outcome;
        marketState = MarketState.RESOLVED;

        emit MarketResolved(outcome);
    }

    // ---------------- REDEMPTION ----------------

    function redeem() external {
        require(marketState == MarketState.RESOLVED, "Not resolved");

        uint payout;
        if (resolvedOutcome == 1) {
            payout = userYes[msg.sender];
            userYes[msg.sender] = 0;
        } else {
            payout = userNo[msg.sender];
            userNo[msg.sender] = 0;
        }

        require(payout > 0, "Nothing to redeem");
        require(collateralToken.transfer(msg.sender, payout), "Transfer failed");

        emit Redeemed(msg.sender, payout);
    }

    // ---------------- SHARE TRANSFERS ----------------

    /// @notice Transfer YES shares to another address.
    function transferYesShares(address _to, uint _amount) external {
        require(_to != address(0), "Invalid recipient");
        require(userYes[msg.sender] >= _amount, "Insufficient YES shares");

        userYes[msg.sender] -= _amount;
        userYes[_to] += _amount;

        emit SharesTransferred(msg.sender, _to, true, _amount);
    }

    /// @notice Transfer NO shares to another address.
    function transferNoShares(address _to, uint _amount) external {
        require(_to != address(0), "Invalid recipient");
        require(userNo[msg.sender] >= _amount, "Insufficient NO shares");

        userNo[msg.sender] -= _amount;
        userNo[_to] += _amount;

        emit SharesTransferred(msg.sender, _to, false, _amount);
    }

    // ---------------- EMERGENCY ----------------

    /// @notice Pause trading on this market. Only callable by the oracle.
    function pause() external onlyOracle {
        require(!paused, "Already paused");
        paused = true;
        emit MarketPaused();
    }

    /// @notice Unpause trading on this market. Only callable by the oracle.
    function unpause() external onlyOracle {
        require(paused, "Not paused");
        paused = false;
        emit MarketUnpaused();
    }
}
