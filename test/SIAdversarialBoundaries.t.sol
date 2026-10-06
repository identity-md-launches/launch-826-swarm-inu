// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIIntegrationFixture} from "./helpers/SIIntegrationFixture.sol";
import {SettlementIMD} from "./mocks/SettlementIMD.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {SICommunityVault} from "src/SICommunityVault.sol";
import {SIFeeHook} from "src/SIFeeHook.sol";
import {SISwapRouter} from "src/SISwapRouter.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract SIAdversarialBoundariesTest is SIIntegrationFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    address internal constant TRADER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    function setUp() public {
        _deploySystem(true);
        _fund(TRADER, 1_000_000 ether);
    }

    function test_feeAndSplitRoundingAtOneWeiAndEachThreshold() public {
        uint256[10] memory amounts = [uint256(1), 2, 49, 50, 51, 99, 100, 249, 250, 251];
        for (uint256 i; i < amounts.length; ++i) {
            _assertFeeOnActualSpend(amounts[i], true, false);
            _assertFeeOnActualSpend(amounts[i], false, false);
            _assertFeeOnActualSpend(amounts[i], true, true);
            _assertFeeOnActualSpend(amounts[i], false, true);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactOutputChargesOnlyInputCurrencyAndExactWalletSpend(uint256 raw, bool buy) public {
        _assertFeeOnActualSpend(bound(raw, 1, 10_000 ether), buy, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromSelfConsumesOnlyFiniteAllowance(uint256 rawAmount, uint256 rawApproval) public {
        uint256 amount = bound(rawAmount, 0, si.balanceOf(TRADER));
        uint256 approved = bound(rawApproval, amount, type(uint256).max);
        vm.prank(TRADER);
        si.approve(RECIPIENT, approved);
        uint256 beforeBalance = si.balanceOf(TRADER);
        vm.prank(RECIPIENT);
        assertTrue(si.transferFrom(TRADER, TRADER, amount));
        assertEq(si.balanceOf(TRADER), beforeBalance);
        assertEq(si.allowance(TRADER, RECIPIENT), approved == type(uint256).max ? approved : approved - amount);
        assertEq(si.totalSupply(), SUPPLY);
    }

    function test_maximumTransferAndFailedDelegatedTransferPreserveState() public {
        uint256 beforeBalance = si.balanceOf(TRADER);
        vm.prank(TRADER);
        si.approve(RECIPIENT, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmInu.ERC20InsufficientBalance.selector, TRADER, beforeBalance, type(uint256).max)
        );
        vm.prank(RECIPIENT);
        si.transferFrom(TRADER, RECIPIENT, type(uint256).max);
        assertEq(si.allowance(TRADER, RECIPIENT), type(uint256).max);
        assertEq(si.balanceOf(TRADER), beforeBalance);
        assertEq(si.balanceOf(RECIPIENT), 0);
    }

    function test_hookRejectsZeroAndOutOfInt128DomainBeforeAnyReservation() public {
        int256 maximum = int256(type(int128).max);
        int256[5] memory invalid = [int256(0), maximum + 1, -maximum - 1, type(int256).min, type(int256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(SIFeeHook.InvalidAmount.selector);
            vm.prank(address(manager));
            hook.beforeSwap(address(router), key, SwapParams(true, invalid[i], TickMath.MIN_SQRT_PRICE + 1), "");
        }
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(si)))), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))), 0);
        _assertFeeOnActualSpend(100 ether, true, false);
    }

    function test_maximumSupportedBudgetReservationDoesNotOverflow() public {
        int256 amount = int256(type(int128).max);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(address(router), key, SwapParams(true, -amount, TickMath.MIN_SQRT_PRICE + 1), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(uint256(uint128(delta.getSpecifiedDelta())), uint256(amount) * 200 / 10_000);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(feeOverride, 0);
    }

    function test_callbackStateMachineRejectsRepetitionAndRecovers() public {
        SwapParams memory params = SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(SIFeeHook.InvalidCallback.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(SIFeeHook.Reentrancy.selector);
        vm.prank(address(manager));
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(SIFeeHook.Reentrancy.selector);
        hook.flush(address(imd), address(vault), 1);
        vm.prank(address(manager));
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIFeeHook.InvalidCallback.selector);
        vm.prank(address(manager));
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
        _assertFeeOnActualSpend(100 ether, true, false);
    }

    function test_everyPoolKeyComponentIsBoundToTheIntendedPool() public {
        for (uint256 i; i < 5; ++i) {
            PoolKey memory bad = key;
            if (i == 0) bad.currency0 = Currency.wrap(address(1));
            if (i == 1) bad.currency1 = Currency.wrap(address(1));
            if (i == 2) bad.fee = 3000;
            if (i == 3) bad.tickSpacing = 1;
            if (i == 4) bad.hooks = IHooks(address(0));
            vm.expectRevert(SIFeeHook.InvalidPool.selector);
            vm.prank(address(manager));
            hook.beforeSwap(address(router), bad, SwapParams(true, -100, TickMath.MIN_SQRT_PRICE + 1), "");
        }
        vm.expectRevert(SIFeeHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        _assertFeeOnActualSpend(100 ether, false, false);
    }

    function test_hookConstructorRejectsMismatchedDependenciesAndMissingCode() public {
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(IPoolManager(address(0)), address(si), address(imd), vault, CREATOR, address(router));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(0), address(imd), vault, CREATOR, address(router));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(si), vault, CREATOR, address(router));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(imd), SICommunityVault(address(0)), CREATOR, address(router));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(imd), vault, address(0), address(router));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(imd), vault, CREATOR, TRADER);
        SICommunityVault swapped = new SICommunityVault(address(imd), address(si));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(imd), swapped, CREATOR, address(router));
        SISwapRouter other = new SISwapRouter(new PoolManager(address(this)));
        vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
        new SIFeeHook(manager, address(si), address(imd), vault, CREATOR, address(other));
        vm.expectRevert(SISwapRouter.InvalidConfiguration.selector);
        new SISwapRouter(IPoolManager(TRADER));
    }

    function test_routerRejectsSelfAndManagerAsRecipientAndUnauthenticatedCallback() public {
        SwapParams memory params = _params(100 ether, true, false);
        vm.expectRevert(SISwapRouter.InvalidConfiguration.selector);
        vm.prank(TRADER);
        router.swap(key, params, type(uint256).max, 0, address(router), block.timestamp);
        vm.expectRevert(SISwapRouter.InvalidConfiguration.selector);
        vm.prank(TRADER);
        router.swap(key, params, type(uint256).max, 0, address(manager), block.timestamp);
        vm.expectRevert(SISwapRouter.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        router.unlockCallback("");
    }

    function test_settlementFailuresRollBackMutationsPayoutsAndFiniteAllowance() public {
        SettlementIMD externalToken = _settlementMock();
        uint256[4] memory modes = [uint256(1), 3, 4, 5];
        for (uint256 i; i < modes.length; ++i) {
            externalToken.configure(modes[i], address(0), "");
            vm.prank(TRADER);
            externalToken.approve(address(router), 100 ether);
            bytes32 beforeState = _balancesAndDebt();
            vm.expectRevert(
                modes[i] == 5
                    ? SISwapRouter.TokenSettlementMismatch.selector
                    : SISwapRouter.TokenTransferFailed.selector
            );
            _trade(100 ether, true, false, TRADER);
            assertEq(_balancesAndDebt(), beforeState, "failed settlement was not atomic");
            assertEq(externalToken.allowance(TRADER, address(router)), 100 ether);
            // A reverted swap must also clear the router/hook's transient operation state.
            externalToken.configure(0, address(0), "");
            _assertFeeOnActualSpend(100 ether, true, false);
        }
    }

    function test_noReturnTransferFromWorksAndOutputGoesToChosenRecipient() public {
        SettlementIMD externalToken = _settlementMock();
        externalToken.configure(2, address(0), "");
        uint256 beforeSI = si.balanceOf(TRADER);
        uint256 beforeIMD = imd.balanceOf(TRADER);
        BalanceDelta delta = _trade(100 ether, true, false, RECIPIENT);
        assertEq(beforeIMD - imd.balanceOf(TRADER), 100 ether);
        assertEq(si.balanceOf(TRADER), beforeSI);
        assertEq(si.balanceOf(RECIPIENT), uint256(int256(delta.amount0())));
        assertGt(si.balanceOf(RECIPIENT), 0);
        assertEq(vault.totalIMDHeld(), 1.6 ether);
        assertEq(imd.balanceOf(CREATOR), 0.4 ether);
    }

    function test_transferFromCallbackCannotStartNestedSwap() public {
        SettlementIMD externalToken = _settlementMock();
        externalToken.configure(
            6,
            address(router),
            abi.encodeCall(router.swap, (key, _params(1 ether, true, false), 1 ether, 0, TRADER, block.timestamp))
        );
        _assertFeeOnActualSpend(100 ether, true, false);
        assertTrue(externalToken.callbackAttempted());
        assertFalse(externalToken.callbackSucceeded());
        externalToken.configure(0, address(0), "");
        _assertFeeOnActualSpend(100 ether, false, false);
    }

    function _settlementMock() private returns (SettlementIMD result) {
        SettlementIMD template = new SettlementIMD();
        vm.etch(address(imd), address(template).code);
        result = SettlementIMD(address(imd));
    }

    function _params(uint256 amount, bool buy, bool exactOutput) private view returns (SwapParams memory) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        return SwapParams(
            zeroForOne,
            exactOutput ? int256(amount) : -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _trade(uint256 amount, bool buy, bool exactOutput, address recipient) private returns (BalanceDelta) {
        SwapParams memory params = _params(amount, buy, exactOutput);
        vm.prank(TRADER);
        return router.swap(key, params, type(uint256).max, 0, recipient, block.timestamp);
    }

    struct FeeSnapshot {
        IERC20 input;
        IERC20 output;
        address other;
        uint256 inputBalance;
        uint256 outputBalance;
        uint256 vaultFees;
        uint256 otherFees;
        uint256 outputFees;
    }

    function _assertFeeOnActualSpend(uint256 amount, bool buy, bool exactOutput) private {
        FeeSnapshot memory snap;
        snap.input = IERC20(buy ? address(imd) : address(si));
        snap.output = IERC20(buy ? address(si) : address(imd));
        snap.inputBalance = snap.input.balanceOf(TRADER);
        snap.outputBalance = snap.output.balanceOf(TRADER);
        snap.other = buy ? CREATOR : DEAD;
        snap.vaultFees = snap.input.balanceOf(address(vault)) + hook.pending(address(snap.input), address(vault));
        snap.otherFees = snap.input.balanceOf(snap.other) + hook.pending(address(snap.input), snap.other);
        snap.outputFees = snap.output.balanceOf(address(vault)) + snap.output.balanceOf(buy ? DEAD : CREATOR);
        BalanceDelta delta = _trade(amount, buy, exactOutput, TRADER);
        uint256 spent = snap.inputBalance - snap.input.balanceOf(TRADER);
        uint256 received = snap.output.balanceOf(TRADER) - snap.outputBalance;
        assertEq(spent, uint256(-int256(buy ? delta.amount1() : delta.amount0())));
        if (exactOutput) assertEq(received, amount);
        else assertEq(spent, amount);
        uint256 fee = spent * 200 / 10_000;
        uint256 otherShare = fee * (buy ? 20 : 50) / 100;
        assertEq(
            snap.input.balanceOf(snap.other) + hook.pending(address(snap.input), snap.other) - snap.otherFees,
            otherShare
        );
        assertEq(
            snap.input.balanceOf(address(vault)) + hook.pending(address(snap.input), address(vault)) - snap.vaultFees,
            fee - otherShare
        );
        assertEq(snap.output.balanceOf(address(vault)) + snap.output.balanceOf(buy ? DEAD : CREATOR), snap.outputFees);
        assertEq(si.totalSupply(), SUPPLY);
    }

    function _balancesAndDebt() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                si.balanceOf(TRADER),
                imd.balanceOf(TRADER),
                si.balanceOf(address(manager)),
                imd.balanceOf(address(manager)),
                vault.totalIMDHeld(),
                imd.balanceOf(CREATOR),
                hook.pending(address(imd), address(vault)),
                hook.pending(address(imd), CREATOR),
                manager.balanceOf(address(hook), uint256(uint160(address(imd)))),
                imd.totalSupply()
            )
        );
    }
}
