// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "forge-std/console.sol";
import {CommissionHook} from "../src/CommissionHook.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20} from "v4-periphery/lib/permit2/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TestCommissionHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Create our tokens for testing
    MockERC20 otherToken;
    MockERC20 docToken;
    
    Currency otherCurrency;
    Currency docCurrency;
    
    bool docIsToken0;

    CommissionHook hook;
    address COMMISSION_RECIPIENT = makeAddr("COMMISSION_RECIPIENT");

    function setUp() public {
        // Check if DOC_IS_TOKEN0 environment variable is set
        // If it's set to "true", we'll force DOC to be token0
        // Otherwise, DOC will be token1
        string memory docIsToken0Env = vm.envOr("DOC_IS_TOKEN0", string("false"));
        docIsToken0 = keccak256(abi.encodePacked(docIsToken0Env)) == keccak256(abi.encodePacked("true"));
        
        console.log("Testing with DOC as token0:", docIsToken0);
        
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();
        // (currency0, currency1) = deployMintAndApprove2Currencies();

        // address hookAddress = address(
        //     uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        // );

        // Deploy our test tokens
        docToken = new MockERC20("DOC Token", "DOC", 18);
        otherToken = new MockERC20("Other Token", "OTHER", 18);
        
        // We need to deploy them in a specific order based on the env variable
        // If docIsToken0 = true, then docToken's address must be lower than otherToken's
        // If docIsToken0 = false, then otherToken's address must be lower than docToken's
        
        // Check if the tokens were deployed with the correct ordering
        bool orderIsRight = address(docToken) < address(otherToken) == docIsToken0;
        
        // If the ordering doesn't match what we want, we need to redeploy them
        // in a way that creates the correct ordering
        if (!orderIsRight) {
            console.log("Reordering token contracts...");
            
            // Use vm.etch to copy the code to new addresses
            // We'll force the address ordering by using explicit addresses
            address docAddr;
            address otherAddr;
            
            if (docIsToken0) {
                // DOC should have lower address
                docAddr = address(0x1000000000000000000000000000000000000000);
                otherAddr = address(0x2000000000000000000000000000000000000000);
            } else {
                // OTHER should have lower address
                otherAddr = address(0x1000000000000000000000000000000000000000);
                docAddr = address(0x2000000000000000000000000000000000000000);
            }
            vm.etch(docAddr, address(docToken).code);
            vm.etch(otherAddr, address(otherToken).code);
            docToken = MockERC20(docAddr);
            otherToken = MockERC20(otherAddr);
        }
        
        // Verify the token ordering is correct
        orderIsRight = address(docToken) < address(otherToken) == docIsToken0;
        require(orderIsRight, "Token ordering doesn't match expected");
        
        console.log("DOC address:", address(docToken));
        console.log("OTHER address:", address(otherToken));
        console.log("Is DOC token0?", docIsToken0);
        
        // Set currencies
        docCurrency = Currency.wrap(address(docToken));
        otherCurrency = Currency.wrap(address(otherToken));
        
        // Set currency0 and currency1 based on the ordering
        if (docIsToken0) {
            currency0 = docCurrency;
            currency1 = otherCurrency;
        } else {
            currency0 = otherCurrency;
            currency1 = docCurrency;
        }

        // Mint test tokens
        docToken.mint(address(this), 100000 ether);
        otherToken.mint(address(this), 100000 ether);

        // Deploy hook to an address with correct flags
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        // Deploy with both tokens
        deployCodeTo("CommissionHook.sol", abi.encode(
            manager, 
            address(docToken), 
            address(otherToken),
            COMMISSION_RECIPIENT
        ), address(flags));

        // Get the hook instance
        hook = CommissionHook(address(flags));

        // Approve tokens for routers
        docToken.approve(address(swapRouter), type(uint256).max);
        otherToken.approve(address(swapRouter), type(uint256).max);
        docToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        otherToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool with the correct token ordering
        (key,) = initPool(
            currency0,      // Currency 0 (lower address)
            currency1,      // Currency 1 (higher address)
            hook,           // Hook Contract
            3000,           // Swap Fees (0.3%)
            SQRT_PRICE_1_1  // Initial Sqrt(P) value = 1 (starting price 1:1)
        );
    }

    function testSwapCommissions() public {
        // First, add some liquidity to the pool
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        // uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 amount0 = 1000 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, SQRT_PRICE_1_1, amount0);
        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, SQRT_PRICE_1_1, liquidityDelta);

        console.log("Adding liquidity: %s token0, %s token1", amount0 / 1e18, amount1 / 1e18);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            bytes("") // Empty hook data
        );

        // Keep track of recipient's DOC balance before the swap
        uint256 recipientBalanceBefore = docToken.balanceOf(COMMISSION_RECIPIENT);
        console.log("Recipient balance before: %s DOC", recipientBalanceBefore / 1e18);

        // Execute a swap - buy DOC with OTHER tokens
        // This should trigger commission based on the size of the swap
        uint256 swapAmount = 200 ether;
        
        // To buy DOC, we need to set zeroForOne correctly:
        // If DOC is token0: zeroForOne = false (swap token1 for token0)
        // If DOC is token1: zeroForOne = true (swap token0 for token1)
        bool zeroForOne = !docIsToken0;
        
        console.log("Swapping to buy DOC, zeroForOne:", zeroForOne);
        
        // Set correct price limit
        uint160 sqrtPriceLimit = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;
        
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapAmount), // Exact input swap
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            bytes("") // Empty hook data
        );
        
        // Calculate approximately how much DOC was received (assuming 1:1 exchange rate)
        uint256 estimatedDocReceived = swapAmount;
        uint256 expectedCommission = (estimatedDocReceived * 10) / 10000; // 0.1% (Tier 4)
        
        // Verify the commission was sent to the recipient
        uint256 recipientBalanceAfter = docToken.balanceOf(COMMISSION_RECIPIENT);
        uint256 actualCommission = recipientBalanceAfter - recipientBalanceBefore;
        
        console.log("Recipient balance after: %s DOC", recipientBalanceAfter / 1e18);
        console.log("Actual commission: %s DOC", actualCommission / 1e18);
        console.log("Expected commission: %s DOC", expectedCommission / 1e18);
        
        // Use approximate comparison because of potential price impact and fees
        assertApproxEqRel(actualCommission, expectedCommission, 0.1e18); // 10% tolerance
    }

    function testUpdateCommissionRecipient() public {
        address newRecipient = address(0xBEEF);
        hook.updateCommissionRecipient(newRecipient);
        assertEq(hook.s_commissionRecipient(), newRecipient);
    }
    
    function testDifferentTiers() public {
        // Add large liquidity for testing different tiers
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        // uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 amount0 = 10000 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, SQRT_PRICE_1_1, amount0);
        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, SQRT_PRICE_1_1, liquidityDelta);

        console.log("Adding liquidity: %s token0, %s token1", amount0 / 1e18, amount1 / 1e18);
        
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        
        // Test different swap sizes to hit different tiers
        
        // Tier 1 (under $100) - 0.04 tokens = $80
        testSwapTier(0.04 ether, 50); // 0.5%
        
        // Tier 2 ($100-$1000) - 0.2 tokens = $400
        testSwapTier(0.2 ether, 30); // 0.3%
        
        // Tier 3 ($1000-$10000) - 2 tokens = $4000
        testSwapTier(2 ether, 20); // 0.2%
        
        // Tier 4 (over $10000) - 6 tokens = $12000
        testSwapTier(6 ether, 10); // 0.1%
    }
    
    function testSwapTier(uint256 swapAmount, uint256 expectedRateBps) internal {
        address recipient = hook.s_commissionRecipient();
        uint256 recipientBalanceBefore = docToken.balanceOf(recipient);

        // Set swap direction to buy DOC
        bool zeroForOne = !docIsToken0;
        
        console.log("\nTesting tier with %s tokens, expected rate: %s bps", swapAmount / 1e18, expectedRateBps);
        console.log("DOC is token0: %s", docIsToken0);
        console.log("zeroForOne: %s", zeroForOne);
        console.log("Recipient balance before: %s DOC", recipientBalanceBefore / 1e18);
        
        // Set correct price limit based on swap direction
        uint160 sqrtPriceLimit = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;
        
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: sqrtPriceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            bytes("")
        );
        
        uint256 recipientBalanceAfter = docToken.balanceOf(recipient);
        uint256 commissionAmount = recipientBalanceAfter - recipientBalanceBefore;
        
        console.log("Recipient balance after: %s DOC", recipientBalanceAfter / 1e18);
        console.log("Commission amount: %s DOC", commissionAmount / 1e18);
        
        // Calculate approximately how much DOC was swapped
        uint256 estimatedDocAmount = swapAmount; // Roughly 1:1 at our starting price
        uint256 expectedCommission = (estimatedDocAmount * expectedRateBps) / 10000;
        
        console.log("Expected commission: %s DOC", expectedCommission / 1e18);
        
        // Use a tolerance for the assertion due to price impact
        assertApproxEqRel(commissionAmount, expectedCommission, 0.1e18); // 10% tolerance
    }
}
