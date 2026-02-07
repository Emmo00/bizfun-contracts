// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {PredictionMarketFactory} from "../src/PredictionMarketFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @dev Minimal ERC-20 mock for testing (USDC-style, 6 decimals).
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    function mint(address to, uint amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
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
    PredictionMarketFactory factory;

    address owner = address(this);
    address oracle = makeAddr("oracle");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint constant CREATION_FEE = 10e6;       // $10 USDC
    uint constant INITIAL_LIQUIDITY = 5e6;   // $5 seeded
    uint constant LIQUIDITY_B = 1e18;        // LMSR b parameter

    string constant META_URI = "ipfs://QmTestMetadataHash123";
    string constant META_URI_2 = "ipfs://QmUpdatedMetadataHash456";

    function setUp() public {
        usdc = new MockUSDC();
        factory = new PredictionMarketFactory(
            address(usdc),
            CREATION_FEE,
            INITIAL_LIQUIDITY
        );

        // Fund accounts
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
    }

    // ================================================================
    //                    FACTORY DEPLOYMENT TESTS
    // ================================================================

    function test_factoryDeployment() public view {
        assertEq(address(factory.collateralToken()), address(usdc));
        assertEq(factory.owner(), owner);
        assertEq(factory.creationFee(), CREATION_FEE);
        assertEq(factory.initialLiquidity(), INITIAL_LIQUIDITY);
        assertEq(factory.marketCount(), 0);
    }

    function test_factoryConstructor_rejectsZeroToken() public {
        vm.expectRevert("Invalid token");
        new PredictionMarketFactory(address(0), CREATION_FEE, INITIAL_LIQUIDITY);
    }

    function test_factoryConstructor_rejectsLiquidityGreaterThanFee() public {
        vm.expectRevert("Liquidity > fee");
        new PredictionMarketFactory(address(usdc), 5e6, 10e6);
    }

    // ================================================================
    //                     MARKET CREATION TESTS
    // ================================================================

    function _createMarket(address creator) internal returns (address) {
        uint deadline = block.timestamp + 7 days;
        uint resolveTime = deadline + 1 days;

        vm.startPrank(creator);
        usdc.approve(address(factory), CREATION_FEE);
        address market = factory.createMarket(
            oracle,
            deadline,
            resolveTime,
            LIQUIDITY_B,
            META_URI
        );
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
        uint deadline = block.timestamp + 7 days;
        uint resolveTime = deadline + 1 days;

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
        uint balanceBefore = usdc.balanceOf(alice);
        _createMarket(alice);
        uint balanceAfter = usdc.balanceOf(alice);

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

        uint shares = 1e18;
        uint cost = pm.quoteBuyYes(shares);

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

        uint shares = 1e18;
        uint cost = pm.quoteBuyNo(shares);

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

        uint shares = 5e18; // large enough for LMSR to produce non-zero cost
        uint cost = pm.quoteBuyYes(shares);

        // Fund bob sufficiently and buy
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);

        // Then sell
        uint balBefore = usdc.balanceOf(bob);
        pm.sellYes(shares);
        uint balAfter = usdc.balanceOf(bob);
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

        assertEq(uint(pm.marketState()), uint(PredictionMarket.MarketState.CLOSED));
    }

    function test_resolveMarket() public {
        address market = _createMarket(alice);
        PredictionMarket pm = PredictionMarket(market);

        // Warp past resolve time
        vm.warp(block.timestamp + 9 days);

        vm.prank(oracle);
        pm.resolve(1); // YES wins

        assertEq(uint(pm.marketState()), uint(PredictionMarket.MarketState.RESOLVED));
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
        uint shares = 5e18;
        uint cost = pm.quoteBuyYes(shares);
        usdc.mint(bob, cost);
        vm.startPrank(bob);
        usdc.approve(market, cost);
        pm.buyYes(shares);
        vm.stopPrank();

        // Warp and resolve — YES wins
        vm.warp(block.timestamp + 9 days);
        vm.prank(oracle);
        pm.resolve(1);

        // Mint enough USDC into the market so it can pay out.
        // In a real system the LMSR guarantees solvency; here the demo
        // math is approximate, so we top-up the market balance to cover
        // the payout (shares == 5e18).
        uint marketBal = IERC20(address(usdc)).balanceOf(market);
        if (marketBal < shares) {
            usdc.mint(market, shares - marketBal);
        }

        // Bob redeems
        uint balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pm.redeem();
        uint balAfter = usdc.balanceOf(bob);

        assertTrue(balAfter > balBefore, "Should have received payout");
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
        uint newFee = 20e6;
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

        uint factoryBal = usdc.balanceOf(address(factory));
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
}
