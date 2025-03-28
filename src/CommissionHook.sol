// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Ownable} from "v4-periphery/lib/permit2/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "v4-periphery/lib/permit2/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";


contract CommissionHook is BaseHook, Ownable {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Commission tiers in USD (using 18 decimals)
    uint256 constant TIER_1_THRESHOLD = 100 ether;  // $100
    uint256 constant TIER_2_THRESHOLD = 1000 ether; // $1,000
    uint256 constant TIER_3_THRESHOLD = 10000 ether; // $10,000

    // Commission rates (in basis points, 1% = 100)
    uint256 constant TIER_1_RATE = 50;  // 0.5%
    uint256 constant TIER_2_RATE = 30;  // 0.3%
    uint256 constant TIER_3_RATE = 20;  // 0.2%
    uint256 constant TIER_4_RATE = 10;  // 0.1%

    // Token addresses
    address public immutable i_docToken;      // The token we take commission in
    address public s_commissionRecipient;

    constructor(
        IPoolManager _poolManager, 
        address _docToken, 
        address _commissionRecipient
    ) BaseHook(_poolManager) Ownable() {
        i_docToken = _docToken;
        s_commissionRecipient = _commissionRecipient;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /*swapParams*/,
        BalanceDelta delta,
        bytes calldata /*hookData*/
    ) internal override onlyPoolManager returns (bytes4, int128) {
        // Verify this is a DOC swap
        if (!_isDocSwap(key)) return (this.afterSwap.selector, 0);

        bool docIsToken0 = Currency.unwrap(key.currency0) == i_docToken;

        // Determine which delta to use for the commission
        int128 docDelta = docIsToken0 ? delta.amount0() : delta.amount1();
        
        // Only take commission when user is buying DOC (delta is positive)
        if (docDelta <= 0) return (this.afterSwap.selector, 0);

        // Calculate commission rate based on swap value
        uint256 commissionRate = _getCommissionRate(uint256(uint128(docDelta)));

        // Calculate commission amount
        uint256 commissionAmount = (uint256(uint128(docDelta)) * commissionRate) / 10000;
        
        int128 commissionDelta = int128(uint128(commissionAmount));

        // Take DOC commission
        Currency doc = docIsToken0 ? key.currency0 : key.currency1;
        poolManager.take(doc, s_commissionRecipient, commissionAmount);
        
        return (this.afterSwap.selector, commissionDelta);
    }

    function _isDocSwap(PoolKey calldata key) internal view returns (bool) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        return token0 == i_docToken || token1 == i_docToken;
    }

    function _getCommissionRate(uint256 docDelta) internal pure returns (uint256) {
        if (docDelta < TIER_1_THRESHOLD) return TIER_1_RATE;
        if (docDelta < TIER_2_THRESHOLD) return TIER_2_RATE;
        if (docDelta < TIER_3_THRESHOLD) return TIER_3_RATE;
        return TIER_4_RATE;
    }

    function updateCommissionRecipient(address newRecipient) external onlyOwner {
        s_commissionRecipient = newRecipient;
    }
} 