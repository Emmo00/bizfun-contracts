// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {PredictionMarketFactory} from "../src/PredictionMarketFactory.sol";

/// @dev Minimal ERC-20 mock for testing (USDC-style, 6 decimals).
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PredictionMarketTest is Test {
    MockUSDC usdc;
    PredictionMarket implementation;
    PredictionMarketFactory factory;

    address owner = address(this);
    address oracle = makeAddr("oracle");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant CREATION_FEE = 10e6; // $10 USDC
    uint256 constant INITIAL_LIQUIDITY = 5e6; // $5 seeded
    uint256 constant LIQUIDITY_B = 1e18; // LMSR b parameter

    string constant META_URI = "ipfs://QmTestMetadataHash123";
    string constant META_URI_2 = "ipfs://QmUpdatedMetadataHash456";

    function setUp() public {
        usdc = new MockUSDC();
        implementation = new PredictionMarket();
        factory = new PredictionMarketFactory(address(usdc), address(implementation), CREATION_FEE, INITIAL_LIQUIDITY);

        // Fund accounts
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
    }

    // ================================================================
    //                    FACTORY DEPLOYMENT TESTS
    // ================================================================

    function test_factoryDeployment() public view {
        assertEq(address(factory.COLLATERAL_TOKEN()), address(usdc));
        assertEq(factory.owner(), owner);
        assertEq(factory.creationFee(), CREATION_FEE);
        assertEq(factory.initialLiquidity(), INITIAL_LIQUIDITY);
        assertEq(factory.marketCount(), 0);
    }

    function test_factoryConstructor_rejectsZeroToken() public {
        vm.expectRevert("Invalid token");
        new PredictionMarketFactory(address(0), address(implementation), CREATION_FEE, INITIAL_LIQUIDITY);
    }

    function test_factoryConstructor_rejectsLiquidityGreaterThanFee() public {
        vm.expectRevert("Liquidity > fee");
        new PredictionMarketFactory(address(usdc), address(implementation), 5e6, 10e6);
    }

    // ================================================================
    //                     MARKET CREATION TESTS
    // ================================================================

    function _createMarket(address creator) internal returns (address) {
        uint256 deadline = block.timestamp + 7 days;
        uint256 resolveTime = deadline + 1 days;

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_FEE);
        address market = factory.createMarket(oracle, deadline, resolveTime, LIQUIDITY_B, META_URI);
        vm.stopPrank();
        return market;
    }

    function test_createMarket_deploysAndStoresInfo() public {
        address market = _createMarket(alice);

        assertEq(factory.marketCount(), 1);
        assertEq(factory.getMarket(0), market);
        assertEq(factory.getAllMarkets().length, 1);
        assertEq(factory.getAllMarkets()[0], market);

        PredictionMarketFactory.MarketInfo memory info = factory.getMarketInfo(0);
        assertEq(info.market, market);
        assertEq(info.creator, alice);
        assertEq(info.metadataURI, META_URI);
        assertEq(info.createdAt, block.timestamp);
    }

    function test_createMarket_emitsEvent() public {
        uint256 deadline = block.timestamp + 7 days;
        uint256 resolveTime = deadline + 1 days;

        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);

        vm.expectEmit(false, false, false, false);
        emit PredictionMarketFactory.MarketCreated(
            0, address(0), alice, oracle, deadline, resolveTime, LIQUIDITY_B, INITIAL_LIQUIDITY, META_URI
        );
        factory.createMarket(oracle, deadline, resolveTime, LIQUIDITY_B, META_URI);
        vm.stopPrank();
    }

    function test_createMarket_collectsFee() public {
        uint256 balanceBefore = usdc.balanceOf(alice);
        _createMarket(alice);
        uint256 balanceAfter = usdc.balanceOf(alice);

        // Alice paid the full creation fee
        assertEq(balanceBefore - balanceAfter, CREATION_FEE);
    }

    function test_createMarket_seedsLiquidity() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // The factory should have bought some YES and NO shares
        assertTrue(pm.yesShares() > 0, "YES shares should be > 0");
        assertTrue(pm.noShares() > 0, "NO shares should be > 0");
    }

    function test_createMarket_setsCreatorOnMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);
        assertEq(pm.creator(), alice);
    }

    function test_createMarket_rejectsZeroOracle() public {
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);
        vm.expectRevert("Invalid oracle");
        factory.createMarket(address(0), block.timestamp + 1 days, block.timestamp + 2 days, LIQUIDITY_B, META_URI);
        vm.stopPrank();
    }

    function test_createMarket_rejectsPastDeadline() public {
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);
        vm.expectRevert("Deadline in past");
        factory.createMarket(oracle, block.timestamp - 1, block.timestamp + 2 days, LIQUIDITY_B, META_URI);
        vm.stopPrank();
    }

    function test_createMarket_rejectsResolveBeforeDeadline() public {
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);
        vm.expectRevert("Resolve before deadline");
        factory.createMarket(oracle, block.timestamp + 7 days, block.timestamp + 1 days, LIQUIDITY_B, META_URI);
        vm.stopPrank();
    }

    function test_createMarket_rejectsEmptyMetadata() public {
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);
        vm.expectRevert("Empty metadata URI");
        factory.createMarket(oracle, block.timestamp + 7 days, block.timestamp + 8 days, LIQUIDITY_B, "");
        vm.stopPrank();
    }

    function test_createMarket_rejectsZeroLiquidityParam() public {
        vm.startPrank(alice);
        usdc.approve(address(factory), CREATION_FEE);
        vm.expectRevert("Invalid liquidity param");
        factory.createMarket(oracle, block.timestamp + 7 days, block.timestamp + 8 days, 0, META_URI);
        vm.stopPrank();
    }

    function test_createMultipleMarkets() public {
        _createMarket(alice);
        _createMarket(bob);

        assertEq(factory.marketCount(), 2);
        assertEq(factory.getAllMarkets().length, 2);
        assertTrue(factory.getMarket(0) != factory.getMarket(1));
    }

    // ================================================================
    //                       METADATA TESTS
    // ================================================================

    function test_getMarketMetadata() public {
        address market = _createMarket(alice);
        assertEq(factory.getMarketMetadata(market), META_URI);
    }

    function test_updateMetadataURI_byCreator() public {
        address market = _createMarket(alice);

        vm.prank(alice);
        factory.updateMetadataURI(market, META_URI_2);

        assertEq(factory.getMarketMetadata(market), META_URI_2);
        assertEq(factory.getMarketInfo(0).metadataURI, META_URI_2);
    }

    function test_updateMetadataURI_emitsEvent() public {
        address market = _createMarket(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PredictionMarketFactory.MetadataUpdated(market, META_URI_2);
        factory.updateMetadataURI(market, META_URI_2);
    }

    function test_updateMetadataURI_rejectsNonCreator() public {
        address market = _createMarket(alice);

        vm.prank(bob);
        vm.expectRevert("Not market creator");
        factory.updateMetadataURI(market, META_URI_2);
    }

    function test_updateMetadataURI_rejectsEmptyURI() public {
        address market = _createMarket(alice);

        vm.prank(alice);
        vm.expectRevert("Empty metadata URI");
        factory.updateMetadataURI(market, "");
    }

    function test_updateMetadataURI_rejectsUnknownMarket() public {
        vm.prank(alice);
        vm.expectRevert("Market not found");
        factory.updateMetadataURI(makeAddr("fake"), META_URI_2);
    }

    // ================================================================
    //                        TRADING TESTS
    // ================================================================

    function test_buyYes_onFactoryDeployedMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        uint256 shares = 1e18;
        uint256 cost = pm.quoteBuyYes(shares);

        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);
        vm.stopPrank();

        assertEq(pm.userYes(bob), shares);
    }

    function test_buyNo_onFactoryDeployedMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        uint256 shares = 1e18;
        uint256 cost = pm.quoteBuyNo(shares);

        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyNo(shares);
        vm.stopPrank();

        assertEq(pm.userNo(bob), shares);
    }

    function test_sellYes_onFactoryDeployedMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        uint256 shares = 5e18; // large enough for LMSR to produce non-zero cost
        uint256 cost = pm.quoteBuyYes(shares);

        // Fund bob sufficiently and buy
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);

        // Then sell
        uint256 balBefore = usdc.balanceOf(bob);
        pm.sellYes(shares);
        uint256 balAfter = usdc.balanceOf(bob);
        vm.stopPrank();

        assertEq(pm.userYes(bob), 0);
        assertTrue(balAfter > balBefore, "Should have received refund");
    }

    function test_trading_rejectsAfterDeadline() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Warp past deadline
        vm.warp(block.timestamp + 8 days);

        vm.startPrank(bob);
        usdc.approve(market, 1e18);
        vm.expectRevert("Trading ended");
        pm.buyYes(1e18);
        vm.stopPrank();
    }

    // ================================================================
    //               LIFECYCLE (CLOSE / RESOLVE / REDEEM)
    // ================================================================

    function test_closeMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.warp(block.timestamp + 8 days); // past deadline
        pm.closeMarket();

        assertEq(uint256(pm.marketState()), uint256(PredictionMarket.MarketState.CLOSED));
    }

    function test_resolveMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Warp past resolve time
        vm.warp(block.timestamp + 9 days);

        vm.prank(oracle);
        pm.resolve(1); // YES wins

        assertEq(uint256(pm.marketState()), uint256(PredictionMarket.MarketState.RESOLVED));
        assertEq(pm.resolvedOutcome(), 1);
    }

    function test_resolve_rejectsNonOracle() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.warp(block.timestamp + 9 days);

        vm.prank(bob);
        vm.expectRevert("Not oracle");
        pm.resolve(1);
    }

    function test_redeem_afterYesWins() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Bob buys YES shares
        uint256 shares = 5e18;
        uint256 cost = pm.quoteBuyYes(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);
        vm.stopPrank();

        // Warp and resolve — YES wins
        vm.warp(block.timestamp + 9 days);
        vm.prank(oracle);
        pm.resolve(1);

        // Bob redeems — pro-rata share of contract balance
        uint256 marketBal = usdc.balanceOf(market);
        uint256 bobShares = pm.userYes(bob);
        uint256 totalYes = pm.yesShares();
        uint256 expectedPayout = (marketBal * bobShares) / totalYes;

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pm.redeem();
        uint256 balAfter = usdc.balanceOf(bob);

        assertEq(balAfter - balBefore, expectedPayout, "Bob should get pro-rata payout");
        assertTrue(expectedPayout > 0, "Payout should be > 0");
        assertEq(pm.userYes(bob), 0);
    }

    function test_redeem_rejectsBeforeResolved() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.prank(bob);
        vm.expectRevert("Not resolved");
        pm.redeem();
    }

    // ================================================================
    //                       ADMIN TESTS
    // ================================================================

    function test_setCreationFee() public {
        uint256 newFee = 20e6;
        factory.setCreationFee(newFee);
        assertEq(factory.creationFee(), newFee);
    }

    function test_setCreationFee_rejectsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Not owner");
        factory.setCreationFee(20e6);
    }

    function test_setCreationFee_rejectsFeeBelowLiquidity() public {
        vm.expectRevert("Fee < liquidity");
        factory.setCreationFee(1e6); // less than INITIAL_LIQUIDITY (5e6)
    }

    function test_setInitialLiquidity() public {
        factory.setInitialLiquidity(3e6);
        assertEq(factory.initialLiquidity(), 3e6);
    }

    function test_setInitialLiquidity_rejectsAboveFee() public {
        vm.expectRevert("Liquidity > fee");
        factory.setInitialLiquidity(20e6);
    }

    function test_withdrawFees() public {
        // Create a market so the factory accumulates fees
        _createMarket(alice);

        uint256 factoryBal = usdc.balanceOf(address(factory));
        assertTrue(factoryBal > 0, "Factory should hold retained fees");

        address treasury = makeAddr("treasury");
        factory.withdrawFees(treasury, factoryBal);
        assertEq(usdc.balanceOf(treasury), factoryBal);
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    function test_withdrawFees_rejectsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Not owner");
        factory.withdrawFees(alice, 1e6);
    }

    function test_transferOwnership() public {
        factory.transferOwnership(alice);
        assertEq(factory.owner(), alice);
    }

    function test_transferOwnership_rejectsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Not owner");
        factory.transferOwnership(alice);
    }

    function test_transferOwnership_rejectsZeroAddress() public {
        vm.expectRevert("Invalid owner");
        factory.transferOwnership(address(0));
    }

    // ================================================================
    //                      VIEW HELPER TESTS
    // ================================================================

    function test_getMarket_rejectsInvalidId() public {
        vm.expectRevert("Invalid market id");
        factory.getMarket(0);
    }

    function test_getMarketInfo_rejectsInvalidId() public {
        vm.expectRevert("Invalid market id");
        factory.getMarketInfo(99);
    }

    function test_getMarketMetadata_rejectsUnknown() public {
        vm.expectRevert("Market not found");
        factory.getMarketMetadata(makeAddr("random"));
    }

    // ================================================================
    //                   SHARE TRANSFER TESTS
    // ================================================================

    function test_transferYesShares() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Bob buys YES shares
        uint256 shares = 2e18;
        uint256 cost = pm.quoteBuyYes(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);

        // Bob transfers half to alice
        uint256 transferAmt = 1e18;
        pm.transferYesShares(alice, transferAmt);
        vm.stopPrank();

        assertEq(pm.userYes(bob), shares - transferAmt);
        assertEq(pm.userYes(alice) >= transferAmt, true); // alice may already have some from liquidity
    }

    function test_transferNoShares() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Bob buys NO shares
        uint256 shares = 2e18;
        uint256 cost = pm.quoteBuyNo(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyNo(shares);

        // Bob transfers half to alice
        uint256 transferAmt = 1e18;
        pm.transferNoShares(alice, transferAmt);
        vm.stopPrank();

        assertEq(pm.userNo(bob), shares - transferAmt);
        assertEq(pm.userNo(alice) >= transferAmt, true);
    }

    function test_transferYesShares_rejectsInsufficientBalance() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.prank(bob);
        vm.expectRevert("Insufficient YES shares");
        pm.transferYesShares(alice, 1e18);
    }

    function test_transferNoShares_rejectsInsufficientBalance() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.prank(bob);
        vm.expectRevert("Insufficient NO shares");
        pm.transferNoShares(alice, 1e18);
    }

    function test_transferYesShares_rejectsZeroAddress() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Alice should have liquidity shares from factory seeding
        uint256 aliceYes = pm.userYes(alice);
        assertTrue(aliceYes > 0, "Alice should have YES shares from liquidity");

        vm.prank(alice);
        vm.expectRevert("Invalid recipient");
        pm.transferYesShares(address(0), aliceYes);
    }

    // ================================================================
    //                  EMERGENCY PAUSE TESTS
    // ================================================================

    function test_pause_blocksTrading() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Oracle pauses the market
        vm.prank(oracle);
        pm.pause();
        assertTrue(pm.paused());

        // Bob tries to buy — should revert
        uint256 shares = 1e18;
        uint256 cost = pm.quoteBuyYes(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        vm.expectRevert("Market paused");
        pm.buyYes(shares);
        vm.stopPrank();
    }

    function test_unpause_resumesTrading() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Pause then unpause
        vm.prank(oracle);
        pm.pause();
        vm.prank(oracle);
        pm.unpause();
        assertFalse(pm.paused());

        // Bob can trade again
        uint256 shares = 1e18;
        uint256 cost = pm.quoteBuyYes(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);
        vm.stopPrank();

        assertEq(pm.userYes(bob), shares);
    }

    function test_pause_rejectsNonOracle() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.prank(bob);
        vm.expectRevert("Not oracle");
        pm.pause();
    }

    function test_unpause_rejectsNonOracle() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        vm.prank(oracle);
        pm.pause();

        vm.prank(bob);
        vm.expectRevert("Not oracle");
        pm.unpause();
    }

    // ================================================================
    //               RESOLVE AUTO-CLOSE TESTS
    // ================================================================

    function test_resolve_autoClosesOpenMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Don't manually close — go straight to resolve
        vm.warp(block.timestamp + 9 days);
        vm.prank(oracle);
        pm.resolve(2); // NO wins

        // Should be RESOLVED (auto-closed internally)
        assertEq(uint256(pm.marketState()), uint256(PredictionMarket.MarketState.RESOLVED));
        assertEq(pm.resolvedOutcome(), 2);
    }

    // ================================================================
    //                  MAX FEE CAP TESTS
    // ================================================================

    function test_setCreationFee_rejectsAboveMaxFee() public {
        uint256 maxFee = factory.MAX_CREATION_FEE();
        vm.expectRevert("Fee exceeds max");
        factory.setCreationFee(maxFee + 1);
    }

    function test_factoryConstructor_rejectsAboveMaxFee() public {
        vm.expectRevert("Fee exceeds max");
        new PredictionMarketFactory(address(usdc), address(implementation), 2000e6, 100e6);
    }

    // ================================================================
    //          CREATOR RECEIVES LIQUIDITY SHARES TESTS
    // ================================================================

    function test_createMarket_transfersLiquiditySharesToCreator() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Factory should hold zero shares
        assertEq(pm.userYes(address(factory)), 0, "Factory should hold 0 YES shares");
        assertEq(pm.userNo(address(factory)), 0, "Factory should hold 0 NO shares");

        // Alice (creator) should hold the liquidity shares
        assertTrue(pm.userYes(alice) > 0, "Creator should hold YES shares");
        assertTrue(pm.userNo(alice) > 0, "Creator should hold NO shares");
    }

    function test_createMarket_seedsFullInitialLiquidity() public {
        address market = _createMarket(alice);

        // The market contract should hold exactly INITIAL_LIQUIDITY of USDC.
        // seedShares transfers USDC directly — no rounding.
        uint256 marketBalance = usdc.balanceOf(market);
        assertEq(marketBalance, INITIAL_LIQUIDITY, "Market should hold full initial liquidity");

        // The factory should retain exactly (CREATION_FEE - INITIAL_LIQUIDITY)
        uint256 factoryBalance = usdc.balanceOf(address(factory));
        assertEq(factoryBalance, CREATION_FEE - INITIAL_LIQUIDITY, "Factory should retain fee minus liquidity");
    }

    // ================================================================
    //             PRO-RATA REDEMPTION SOLVENCY TESTS
    // ================================================================

    function test_redeem_proRata_alwaysSolvent() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Bob buys a large YES position
        uint256 bobShares = 10e18;
        uint256 bobCost = pm.quoteBuyYes(bobShares);
        usdc.mint(bob, bobCost);
        vm.startPrank(bob);
        usdc.approve(market, bobCost);
        pm.buyYes(bobShares);
        vm.stopPrank();

        // Warp and resolve — YES wins
        vm.warp(block.timestamp + 9 days);
        vm.prank(oracle);
        pm.resolve(1);

        uint256 marketBalBefore = usdc.balanceOf(market);

        // Snapshot balances before redemptions
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 bobBalBefore = usdc.balanceOf(bob);

        // Alice redeems first (she has seeded shares)
        uint256 aliceYes = pm.userYes(alice);
        assertTrue(aliceYes > 0, "Alice should have YES shares");
        vm.prank(alice);
        pm.redeem();

        // Bob redeems second
        vm.prank(bob);
        pm.redeem();

        // Market should be fully drained (within rounding)
        uint256 marketBalAfter = usdc.balanceOf(market);
        assertLe(marketBalAfter, 1, "Market should be ~empty after all redemptions");

        // Total paid out should equal the market balance before redemptions
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBalBefore;
        uint256 bobPayout = usdc.balanceOf(bob) - bobBalBefore;
        assertApproxEqAbs(alicePayout + bobPayout, marketBalBefore, 1, "Total payouts should equal contract balance");
    }

    function test_redeem_proRata_creatorGetsShare() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // No additional traders — only creator's seeded shares
        // Warp and resolve — YES wins
        vm.warp(block.timestamp + 9 days);
        vm.prank(oracle);
        pm.resolve(1);

        // Alice redeems — she should get the full contract balance
        uint256 marketBal = usdc.balanceOf(market);
        assertTrue(marketBal > 0, "Market should have USDC");

        vm.prank(alice);
        pm.redeem();

        assertEq(usdc.balanceOf(market), 0, "Market should be empty");
        assertEq(pm.userYes(alice), 0);
    }
}
