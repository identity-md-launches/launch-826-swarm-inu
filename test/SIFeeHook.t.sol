// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {SICommunityVault} from "../src/SICommunityVault.sol";
import {SIFeeHook} from "../src/SIFeeHook.sol";
import {SISwapRouter} from "../src/SISwapRouter.sol";
import {LaunchLiquidity} from "../src/LaunchLiquidity.sol";
import {AdversarialIMD} from "./mocks/AdversarialIMD.sol";

contract SIFeeHookTest is Test, IUnlockCallback {
    SwarmInu internal si;
    AdversarialIMD internal imd;
    PoolManager internal manager;
    SICommunityVault internal vault;
    SIFeeHook internal hook;
    SISwapRouter internal router;
    PoolKey internal key;
    uint8 internal callbackAction;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0xB0B);
    uint160 internal constant Q96 = 79228162514264337593543950336;

    function setUp() public {
        _deploy(true, false);
    }

    function _deploy(bool siFirst, bool singleSided) internal {
        si = new SwarmInu();
        AdversarialIMD template = new AdversarialIMD();
        address pairAt = address(uint160(address(si)) + (siFirst ? 1 : 0));
        if (!siFirst) pairAt = address(uint160(address(si)) - 1);
        vm.etch(pairAt, address(template).code);
        imd = AdversarialIMD(pairAt);
        imd.mint(address(this), 1_000_000_000 ether);
        manager = new PoolManager(address(this));
        router = new SISwapRouter(manager);
        vault = new SICommunityVault(address(si), address(imd));
        bytes memory code = abi.encodePacked(
            type(SIFeeHook).creationCode,
            abi.encode(manager, address(si), address(imd), vault, CREATOR, address(router))
        );
        bytes32 hash = keccak256(code);
        bytes32 salt;
        for (uint256 nonce;; ++nonce) {
            salt = bytes32(nonce);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & 0x3fff == 0x20cc) break;
        }
        hook = new SIFeeHook{salt: salt}(manager, address(si), address(imd), vault, CREATOR, address(router));
        key = PoolKey(
            Currency.wrap(siFirst ? address(si) : address(imd)),
            Currency.wrap(siFirst ? address(imd) : address(si)),
            0,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, Q96);
        int24 lower = singleSided && siFirst ? int24(0) : int24(-60000);
        int24 upper = singleSided && !siFirst ? int24(0) : int24(60000);
        manager.unlock(abi.encode(LaunchLiquidity.Seed(key, lower, upper, 1_000_000 ether)));
        si.transfer(TRADER, 10_000_000 ether);
        imd.mint(TRADER, 10_000_000 ether);
        vm.startPrank(TRADER);
        si.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        if (callbackAction == 1) {
            (BalanceDelta delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(-60000, 60000, -int256(1_000_000 ether), bytes32(0)), ""
            );
            LaunchLiquidity.settle(manager, key.currency0, delta.amount0());
            LaunchLiquidity.settle(manager, key.currency1, delta.amount1());
        } else if (callbackAction == 2) {
            uint256 amount = abi.decode(data, (uint256));
            Currency currency = Currency.wrap(address(imd));
            manager.mint(address(router), currency.toId(), amount);
            LaunchLiquidity.settle(manager, currency, -int128(int256(amount)));
        } else {
            LaunchLiquidity.settleSeed(manager, data);
        }
        return "";
    }

    function _swap(bool buy, int256 specified) internal returns (BalanceDelta) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(TRADER);
        return router.swap(key, SwapParams(zeroForOne, specified, limit), type(uint128).max, 0, TRADER, block.timestamp);
    }

    function _input(BalanceDelta delta, bool buy) internal view returns (uint256) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        return uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
    }

    function _output(BalanceDelta delta, bool buy) internal view returns (uint256) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        return uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
    }

    function _checkClaims() internal view {
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(imd)))),
            hook.pending(address(imd), address(vault)) + hook.pending(address(imd), CREATOR)
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(si)))),
            hook.pending(address(si), address(vault)) + hook.pending(address(si), hook.DEAD())
        );
        assertEq(manager.balanceOf(address(router), uint256(uint160(address(imd)))), 0);
        assertEq(manager.balanceOf(address(router), uint256(uint160(address(si)))), 0);
        assertEq(si.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_exactInputBuysAndSellsChargeInputCurrency() public {
        BalanceDelta bought = _swap(true, -1000 ether);
        assertEq(_input(bought, true), 1000 ether);
        assertGt(_output(bought, true), 0);
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        assertEq(vault.totalSILocked(), 0);

        BalanceDelta sold = _swap(false, -1000 ether);
        assertEq(_input(sold, false), 1000 ether);
        assertGt(_output(sold, false), 0);
        assertEq(vault.totalSILocked(), 10 ether);
        assertEq(vault.totalSIBurned(), 10 ether);
        assertEq(si.balanceOf(CREATOR), 0);
        assertEq(si.totalSupply(), 1_000_000_000 ether);
        _checkClaims();
    }

    function test_exactOutputBuysAndSellsChargeGrossInputFee() public {
        BalanceDelta bought = _swap(true, 500 ether);
        uint256 buyFee = vault.totalIMDHeld() + imd.balanceOf(CREATOR);
        assertEq(_output(bought, true), 500 ether);
        assertEq(buyFee, _input(bought, true) / 50);
        assertEq(imd.balanceOf(CREATOR), buyFee / 5);
        assertEq(vault.totalIMDHeld(), buyFee - buyFee / 5);

        BalanceDelta sold = _swap(false, 300 ether);
        uint256 sellFee = vault.totalSILocked() + vault.totalSIBurned();
        assertEq(_output(sold, false), 300 ether);
        assertEq(sellFee, _input(sold, false) / 50);
        assertEq(vault.totalSIBurned(), sellFee / 2);
        assertEq(vault.totalSILocked(), sellFee - sellFee / 2);
        _checkClaims();
    }

    function test_reverseTokenOrdering() public {
        _deploy(false, false);
        BalanceDelta bought = _swap(true, -1000 ether);
        BalanceDelta sold = _swap(false, -1000 ether);
        assertEq(_input(bought, true), 1000 ether);
        assertEq(_input(sold, false), 1000 ether);
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        assertEq(vault.totalSILocked(), 10 ether);
        assertEq(vault.totalSIBurned(), 10 ether);
        _checkClaims();
    }

    function test_firstSingleSidedBuyDefersThenAnyoneCanFlush() public {
        _deploy(true, true);
        assertEq(imd.balanceOf(address(manager)), 0);
        _swap(true, -1000 ether);
        assertEq(vault.totalIMDHeld(), 0);
        assertEq(imd.balanceOf(CREATOR), 0);
        assertEq(hook.pending(address(imd), address(vault)), 16 ether);
        assertEq(hook.pending(address(imd), CREATOR), 4 ether);
        _checkClaims();
        vm.prank(address(0xCAFE));
        assertTrue(hook.flush(address(imd), address(vault), 10 ether));
        assertEq(hook.pending(address(imd), address(vault)), 6 ether);
        assertTrue(hook.flush(address(imd), address(vault), 6 ether));
        assertTrue(hook.flush(address(imd), CREATOR, 4 ether));
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        _checkClaims();
    }

    function test_failedRecipientsDoNotBrickAndFailedRetryIsAtomic() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.FalseAfterTransfer);
        imd.setMode(CREATOR, AdversarialIMD.Mode.RevertTransfer);
        _swap(true, -1000 ether);
        assertEq(vault.totalIMDHeld(), 0, "false-return mutation must roll back");
        assertEq(imd.balanceOf(CREATOR), 0);
        assertEq(hook.pending(address(imd), address(vault)), 16 ether);
        assertEq(hook.pending(address(imd), CREATOR), 4 ether);
        assertFalse(hook.flush(address(imd), address(vault), 16 ether));
        _checkClaims();
        assertEq(hook.pending(address(imd), address(vault)), 16 ether);
        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        imd.setMode(CREATOR, AdversarialIMD.Mode.Normal);
        assertTrue(hook.flush(address(imd), address(vault), 16 ether));
        assertTrue(hook.flush(address(imd), CREATOR, 4 ether));
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        _checkClaims();
    }

    function test_gasGriefDeferredAndNoReturnSupported() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.GasGrief);
        imd.setMode(CREATOR, AdversarialIMD.Mode.NoReturn);
        _swap(true, -1000 ether);
        assertEq(hook.pending(address(imd), address(vault)), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        assertEq(hook.pending(address(imd), CREATOR), 0);
        _checkClaims();
    }

    function test_reentryDuringPayoutCannotFlushOrCorruptAccounting() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.Reenter);
        imd.setReentry(address(hook), abi.encodeCall(hook.flush, (address(imd), CREATOR, 1)));
        _swap(true, -1000 ether);
        assertTrue(imd.reentryAttempted());
        assertFalse(imd.reentrySucceeded());
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        _checkClaims();
    }

    function test_partialExactInputRefundsUnusedFeeClaims() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        uint256 budget = 1_000_000 ether;
        uint256 beforeBalance = imd.balanceOf(TRADER);
        vm.prank(TRADER);
        BalanceDelta delta =
            router.swap(key, SwapParams(zeroForOne, -int256(budget), limit), budget, 1, TRADER, block.timestamp);
        uint256 spent = _input(delta, true);
        uint256 paidFee = vault.totalIMDHeld() + imd.balanceOf(CREATOR);
        assertGt(spent, 0);
        assertLt(spent, budget);
        assertEq(beforeBalance - imd.balanceOf(TRADER), spent);
        assertEq(paidFee, spent / 50);
        assertLt(paidFee, budget / 50);
        _checkClaims();
    }

    function test_partialExactOutputHasFeeOnActualInputAndHonorsMinimum() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        uint256 requested = 500_000 ether;
        vm.prank(TRADER);
        BalanceDelta delta = router.swap(
            key, SwapParams(zeroForOne, int256(requested), limit), type(uint128).max, 1, TRADER, block.timestamp
        );
        assertLt(_output(delta, true), requested);
        assertEq(vault.totalIMDHeld() + imd.balanceOf(CREATOR), _input(delta, true) / 50);
        _checkClaims();
    }

    function test_routerLimitsRollbackAllFeeTransfers() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory params = SwapParams(zeroForOne, -1000 ether, limit);
        uint256 beforeBalance = imd.balanceOf(TRADER);
        vm.expectRevert(SISwapRouter.InputLimitExceeded.selector);
        vm.prank(TRADER);
        router.swap(key, params, 999 ether, 0, TRADER, block.timestamp);
        vm.expectRevert(SISwapRouter.OutputLimitNotMet.selector);
        vm.prank(TRADER);
        router.swap(key, params, 1000 ether, 1001 ether, TRADER, block.timestamp);
        assertEq(imd.balanceOf(TRADER), beforeBalance);
        assertEq(vault.totalIMDHeld(), 0);
        assertEq(imd.balanceOf(CREATOR), 0);
        _checkClaims();
    }

    function test_callbacksAndDeliveryRejectUnauthorizedCallers() public {
        vm.expectRevert(SIFeeHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(SIFeeHook.OnlyPoolManager.selector);
        hook.afterSwap(
            address(this), key, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), ""
        );
        vm.expectRevert(SIFeeHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SIFeeHook.OnlySelf.selector);
        hook.deliver(Currency.wrap(address(imd)), TRADER, 1);
        vm.expectRevert(SISwapRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
        vm.expectRevert(SIFeeHook.InvalidCallback.selector);
        vm.prank(address(manager));
        hook.unlockCallback("");
    }

    function test_poolValidationAndPermissionlessInitialization() public {
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert(SIFeeHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), bad, Q96);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(TRADER, key, Q96), IHooks.beforeInitialize.selector);
        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert(SIFeeHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(TRADER, bad, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1), "");
    }

    function test_flushCannotRedirectOrExceedFixedDebt() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.RevertTransfer);
        _swap(true, -1000 ether);
        vm.expectRevert(SIFeeHook.InvalidAmount.selector);
        hook.flush(address(imd), TRADER, 16 ether);
        vm.expectRevert(SIFeeHook.InvalidAmount.selector);
        hook.flush(address(imd), address(vault), 16 ether + 1);
        vm.expectRevert(SIFeeHook.InvalidAmount.selector);
        hook.flush(address(imd), address(vault), 0);
        _checkClaims();
    }

    function testFuzz_feeSplitsAndConservation(uint96 amount, bool buy) public {
        uint256 inputAmount = bound(uint256(amount), 100, 100_000 ether);
        BalanceDelta delta = _swap(buy, -int256(inputAmount));
        uint256 fee = inputAmount / 50;
        assertEq(_input(delta, buy), inputAmount);
        if (buy) {
            assertEq(vault.totalIMDHeld(), fee - fee / 5);
            assertEq(imd.balanceOf(CREATOR), fee / 5);
        } else {
            assertEq(vault.totalSILocked(), fee - fee / 2);
            assertEq(vault.totalSIBurned(), fee / 2);
        }
        _checkClaims();
    }

    function test_emptyLiquidityRefundsEntireReservation() public {
        callbackAction = 1;
        manager.unlock("");
        callbackAction = 0;
        uint256 beforeBalance = imd.balanceOf(TRADER);
        BalanceDelta delta = _swap(true, -1000 ether);
        assertEq(_input(delta, true), 0);
        assertEq(_output(delta, true), 0);
        assertEq(imd.balanceOf(TRADER), beforeBalance);
        assertEq(vault.totalIMDHeld(), 0);
        _checkClaims();
    }

    function test_existingRouterClaimsAreNotSpentByNextTrader() public {
        uint256 donation = 123 ether;
        callbackAction = 2;
        manager.unlock(abi.encode(donation));
        callbackAction = 0;
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        vm.prank(TRADER);
        BalanceDelta delta = router.swap(
            key, SwapParams(zeroForOne, -int256(1_000_000 ether), limit), 1_000_000 ether, 1, TRADER, block.timestamp
        );
        assertLt(_input(delta, true), 1_000_000 ether);
        assertEq(manager.balanceOf(address(router), uint256(uint160(address(imd)))), donation);
        assertEq(vault.totalIMDHeld() + imd.balanceOf(CREATOR), _input(delta, true) / 50);
    }

    function test_alternateRouterFullFillWorksButPartialFillRollsBack() public {
        SISwapRouter alternate = new SISwapRouter(manager);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.startPrank(TRADER);
        imd.approve(address(alternate), type(uint256).max);
        alternate.swap(key, SwapParams(zeroForOne, -1000 ether, limit), 1000 ether, 1, TRADER, block.timestamp);
        uint256 beforeBalance = imd.balanceOf(TRADER);
        uint256 beforeVault = vault.totalIMDHeld();
        limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        vm.expectRevert();
        alternate.swap(
            key, SwapParams(zeroForOne, -int256(1_000_000 ether), limit), 1_000_000 ether, 1, TRADER, block.timestamp
        );
        vm.stopPrank();
        assertEq(imd.balanceOf(TRADER), beforeBalance);
        assertEq(vault.totalIMDHeld(), beforeVault);
        _checkClaims();
    }

    function test_routerDeadlineRecipientAndAllowanceFailures() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(imd);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory params = SwapParams(zeroForOne, -1000 ether, limit);
        vm.warp(10);
        vm.startPrank(TRADER);
        vm.expectRevert(SISwapRouter.DeadlineExpired.selector);
        router.swap(key, params, 1000 ether, 1, TRADER, 9);
        vm.expectRevert(SISwapRouter.InvalidConfiguration.selector);
        router.swap(key, params, 1000 ether, 1, address(0), 10);
        imd.approve(address(router), 0);
        vm.expectRevert(SISwapRouter.TokenTransferFailed.selector);
        router.swap(key, params, 1000 ether, 1, TRADER, 10);
        vm.stopPrank();
        assertEq(vault.totalIMDHeld(), 0);
        _checkClaims();
    }

    function test_shortReturnAndReturnBombCannotBrickPayouts() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.ShortReturn);
        imd.setMode(CREATOR, AdversarialIMD.Mode.ReturnBomb);
        _swap(true, -1000 ether);
        assertEq(vault.totalIMDHeld(), 0);
        assertEq(imd.balanceOf(CREATOR), 0);
        assertEq(hook.pending(address(imd), address(vault)), 16 ether);
        assertEq(hook.pending(address(imd), CREATOR), 4 ether);
        _checkClaims();
    }
}
