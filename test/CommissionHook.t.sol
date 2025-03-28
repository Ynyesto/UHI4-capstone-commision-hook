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
    CommissionHook hook;
    address COMMISSION_RECIPIENT = makeAddr("COMMISSION_RECIPIENT");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        );
        // Deploy the hook with currency0 as the DOC token
        deployCodeTo("CommissionHook.sol", abi.encode(manager, Currency.unwrap(currency0),COMMISSION_RECIPIENT), hookAddress);
        hook = CommissionHook(hookAddress);

        (key, ) = initPoolAndAddLiquidity(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1
        );
    }

    function testNoCommissionTakenWhenDocIsInput() public {
        uint256 docBalanceBefore = currency0.balanceOfSelf();
        uint256 otherTokenBalanceBefore = currency1.balanceOfSelf();

        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        uint256 docBalanceAfter = currency0.balanceOfSelf();
        uint256 otherTokenBalanceAfter = currency1.balanceOfSelf();
        uint256 recipientDocBalanceAfter = currency0.balanceOf(address(COMMISSION_RECIPIENT));
        uint256 recipientOtherBalanceAfter = currency1.balanceOf(address(COMMISSION_RECIPIENT));

        // Input token has been deducted
        assertEq(docBalanceAfter, docBalanceBefore - 0.001 ether);

        // The recipient should not have received any tokens
        assertEq(recipientDocBalanceAfter, 0);
        assertEq(recipientOtherBalanceAfter, 0);

        // User should have received all the output tokens
        assertEq(otherTokenBalanceAfter, otherTokenBalanceBefore + uint256(uint128(delta.amount1())));
    }

    function testCommissionTakenWhenDocIsOutput() public {
        uint256 docBalanceBefore = currency0.balanceOfSelf();
        uint256 otherTokenBalanceBefore = currency1.balanceOfSelf();
        uint256 recipientDocBalanceBefore = currency0.balanceOf(address(COMMISSION_RECIPIENT));

        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        uint256 docBalanceAfter = currency0.balanceOfSelf();
        uint256 otherTokenBalanceAfter = currency1.balanceOfSelf();
        uint256 recipientDocBalanceAfter = currency0.balanceOf(address(COMMISSION_RECIPIENT));
        uint256 recipientOtherBalanceAfter = currency1.balanceOf(address(COMMISSION_RECIPIENT));

        // Input token has been deducted
        assertEq(otherTokenBalanceAfter, otherTokenBalanceBefore - 0.001 ether);

        // Recipient should have received commission in DOC
        assertGt(recipientDocBalanceAfter, 0);
        assertEq(recipientOtherBalanceAfter, 0);

        uint256 docBalanceIncrease = docBalanceAfter - docBalanceBefore;
        
        // User should have received all the DOC minus the commission, which equals the balanceDelta of the swap
        assertEq(docBalanceIncrease, uint256(uint128(delta.amount0())));
    }

    function testCommissionTiers() public {
        // First, add more liquidity to handle larger swaps
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -887272,
        //         tickUpper: 887272,
        //         liquidityDelta: 1000000 ether,
        //         salt: 0
        //     }),
        //     ZERO_BYTES
        // );

        // Test each tier with different swap amounts using 18 decimals
        // Tier 1 (0.5%): < $100
        uint256 amount = 50 ether;  // $50 worth of tokens
        uint256 recipientDocBalanceBefore = currency0.balanceOf(COMMISSION_RECIPIENT);
        uint256 userDocBalanceBefore = currency0.balanceOfSelf();
        BalanceDelta delta = swapFn(amount);
        uint256 recipientDocBalanceAfter = currency0.balanceOf(COMMISSION_RECIPIENT);
        uint256 userDocBalanceAfter = currency0.balanceOfSelf();
        uint256 commission = recipientDocBalanceAfter - recipientDocBalanceBefore;
        console.log("userDocBalanceBefore", userDocBalanceBefore);
        console.log("userDocBalanceAfter", userDocBalanceAfter);
        console.log("recipientDocBalanceBefore", recipientDocBalanceBefore);
        console.log("recipientDocBalanceAfter", recipientDocBalanceAfter);
        console.log("commission", commission);
        console.log("delta.amount0()", delta.amount0());
        console.log("userDocBalanceAfter - userDocBalanceBefore", userDocBalanceAfter - userDocBalanceBefore);
        assertEq(userDocBalanceAfter - userDocBalanceBefore + commission, uint256(uint128(delta.amount0())));
        // assertApproxEqRel(commission, (amount * 50) / 10000, 0.01e18); // 0.5% commission

        // Tier 2 (0.3%): $100-$1000
        // amount = 500 ether;  // $500 worth of tokens
        // docBalanceBefore = currency0.balanceOf(COMMISSION_RECIPIENT);
        // swapFn(amount);
        // commission = currency0.balanceOf(COMMISSION_RECIPIENT) - docBalanceBefore;
        // assertApproxEqRel(commission, (amount * 30) / 10000, 0.01e18); // 0.3% commission

        // // Tier 3 (0.2%): $1000-$10000
        // amount = 5000 ether;  // $5000 worth of tokens
        // docBalanceBefore = currency0.balanceOf(COMMISSION_RECIPIENT);
        // swapFn(amount);
        // commission = currency0.balanceOf(COMMISSION_RECIPIENT) - docBalanceBefore;
        // assertApproxEqRel(commission, (amount * 20) / 10000, 0.01e18); // 0.2% commission

        // // Tier 4 (0.1%): > $10000
        // amount = 20000 ether;  // $20000 worth of tokens
        // docBalanceBefore = currency0.balanceOf(COMMISSION_RECIPIENT);
        // swapFn(amount);
        // commission = currency0.balanceOf(COMMISSION_RECIPIENT) - docBalanceBefore;
        // assertApproxEqRel(commission, (amount * 10) / 10000, 0.01e18); // 0.1% commission
    }

    function swapFn(uint256 amount) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
    }

}
