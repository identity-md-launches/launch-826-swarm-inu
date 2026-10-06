// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIIntegrationFixture} from "../helpers/SIIntegrationFixture.sol";
import {AdversarialIMD} from "../mocks/AdversarialIMD.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {SICommunityVault} from "src/SICommunityVault.sol";
import {SIFeeHook} from "src/SIFeeHook.sol";
import {SISwapRouter} from "src/SISwapRouter.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract SIFeeSequenceHandler is Test {
    using StateLibrary for IPoolManager;

    SwarmInu public immutable si;
    AdversarialIMD public immutable imd;
    SIFeeHook public immutable hook;
    SISwapRouter public immutable router;
    SICommunityVault public immutable vault;
    IPoolManager public immutable manager;
    PoolKey internal key;
    address[3] public actors = [address(0x1001), address(0x1002), address(0x1003)];
    address public immutable creator;
    address private constant DEAD = address(0xdEaD);

    // Derived only from trader balance changes and the requested economic split.
    uint256 public earnedVaultIMD;
    uint256 public earnedCreatorIMD;
    uint256 public earnedVaultSI;
    uint256 public earnedBurnSI;
    uint256 public donatedVaultSI;
    uint256 public donatedBurnSI;
    uint256 public swaps;
    uint256 public partialFills;
    uint256 public successfulFlushes;
    uint256 public failedFlushes;
    uint256 public rejectedSwaps;

    constructor(SIFeeHook hook_, SISwapRouter router_, PoolKey memory key_) {
        hook = hook_;
        router = router_;
        si = SwarmInu(hook_.si());
        imd = AdversarialIMD(hook_.imd());
        vault = hook_.vault();
        manager = hook_.poolManager();
        creator = hook_.creatorReceiver();
        key = key_;
    }

    function swap(uint256 actorSeed, uint256 raw, bool buy, bool exactOutput, bool limitedPrice) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(raw, 1, exactOutput ? 100 ether : 1000 ether);
        _swap(actor, amount, buy, exactOutput, limitedPrice);
    }

    function roundTrip(uint256 actorSeed, uint256 raw) public {
        address actor = actors[actorSeed % 3];
        uint256 beforeIMD = imd.balanceOf(actor);
        uint256 beforeSI = si.balanceOf(actor);
        uint256 bought = _swap(actor, bound(raw, 1, 1000 ether), true, false, false);
        if (bought != 0) _swap(actor, bought, false, false, false);
        assertEq(si.balanceOf(actor), beforeSI, "round trip retained SI");
        assertLe(imd.balanceOf(actor), beforeIMD, "round trip created value");
    }

    function setPayoutBehavior(uint256 rawMode, bool creatorRecipient) public {
        // Include failures after mutation, malformed return data, out-of-gas, and callbacks.
        AdversarialIMD.Mode mode = AdversarialIMD.Mode(rawMode % 10);
        imd.setMode(creatorRecipient ? creator : address(vault), mode);
        if (mode == AdversarialIMD.Mode.Reenter) {
            imd.setReentry(address(hook), abi.encodeCall(hook.flush, (address(imd), creator, 1)));
        }
    }

    function flush(uint256 selection, uint256 rawAmount, uint256 actorSeed) public {
        (address token, address recipient) = _debt(selection);
        uint256 debt = hook.pending(token, recipient);
        if (debt == 0) {
            vm.expectRevert(SIFeeHook.InvalidAmount.selector);
            vm.prank(actors[actorSeed % 3]);
            hook.flush(token, recipient, 0);
            return;
        }
        uint256 amount = bound(rawAmount, 1, debt);
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        uint256 beforeClaims = manager.balanceOf(address(hook), uint256(uint160(token)));
        vm.prank(actors[actorSeed % 3]);
        bool delivered = hook.flush{gas: 1_000_000}(token, recipient, amount);
        if (delivered) {
            assertEq(hook.pending(token, recipient), debt - amount, "flush did not consume exact debt");
            assertEq(IERC20(token).balanceOf(recipient), beforeBalance + amount, "flush delivered wrong amount");
            assertEq(manager.balanceOf(address(hook), uint256(uint160(token))), beforeClaims - amount);
            ++successfulFlushes;
        } else {
            assertEq(hook.pending(token, recipient), debt, "failed flush changed debt");
            assertEq(IERC20(token).balanceOf(recipient), beforeBalance, "failed flush moved tokens");
            assertEq(manager.balanceOf(address(hook), uint256(uint160(token))), beforeClaims);
            ++failedFlushes;
        }
    }

    function donateSI(uint256 actorSeed, uint256 raw, bool burn) public {
        address actor = actors[actorSeed % 3];
        // Keep actor funding available for later swaps; the separate token campaign donates full balances.
        uint256 amount = bound(raw, 0, 100 ether);
        vm.prank(actor);
        si.transfer(burn ? DEAD : address(vault), amount);
        if (burn) donatedBurnSI += amount;
        else donatedVaultSI += amount;
    }

    function rejectedSwap(uint256 actorSeed, uint256 raw, bool buy, bool revokeApproval) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(raw, 100, 1000 ether);
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        IERC20 input = IERC20(buy ? address(imd) : address(si));
        if (revokeApproval) {
            vm.prank(actor);
            input.approve(address(router), 0);
        }
        bytes32 beforeState = _stateDigest(actor);
        vm.expectRevert(
            revokeApproval ? SISwapRouter.TokenTransferFailed.selector : SISwapRouter.InputLimitExceeded.selector
        );
        vm.prank(actor);
        router.swap(
            key,
            SwapParams(zeroForOne, -int256(amount), _limit(zeroForOne, false)),
            revokeApproval ? type(uint256).max : 0,
            0,
            actor,
            block.timestamp
        );
        assertEq(_stateDigest(actor), beforeState, "reverted swap leaked state");
        if (revokeApproval) {
            vm.prank(actor);
            input.approve(address(router), type(uint256).max);
        }
        ++rejectedSwaps;
    }

    struct SwapSnapshot {
        bool zeroForOne;
        IERC20 input;
        IERC20 output;
        uint256 inputBefore;
        uint256 outputBefore;
    }

    function _swap(address actor, uint256 amount, bool buy, bool exactOutput, bool limitedPrice)
        private
        returns (uint256 outputAmount)
    {
        SwapSnapshot memory snap;
        snap.zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        snap.input = IERC20(buy ? address(imd) : address(si));
        snap.output = IERC20(buy ? address(si) : address(imd));
        snap.inputBefore = snap.input.balanceOf(actor);
        snap.outputBefore = snap.output.balanceOf(actor);
        SwapParams memory params = SwapParams(
            snap.zeroForOne, exactOutput ? int256(amount) : -int256(amount), _limit(snap.zeroForOne, limitedPrice)
        );
        vm.prank(actor);
        BalanceDelta delta = router.swap(key, params, snap.inputBefore, 0, actor, block.timestamp);
        uint256 paid = snap.inputBefore - snap.input.balanceOf(actor);
        outputAmount = snap.output.balanceOf(actor) - snap.outputBefore;
        assertEq(paid, uint256(-int256(snap.zeroForOne ? delta.amount0() : delta.amount1())));
        assertEq(outputAmount, uint256(int256(snap.zeroForOne ? delta.amount1() : delta.amount0())));
        if (exactOutput) {
            assertLe(outputAmount, amount);
            if (!limitedPrice) assertEq(outputAmount, amount);
            if (outputAmount < amount) ++partialFills;
        } else {
            assertLe(paid, amount);
            if (!limitedPrice) assertEq(paid, amount);
            if (paid < amount) ++partialFills;
        }
        if (outputAmount != 0) assertGt(paid, 0, "free output");
        // Oracle is the 2% specification applied to actual wallet spend, including partial fills.
        uint256 fee = paid * 200 / 10_000;
        if (buy) {
            uint256 creatorShare = fee * 20 / 100;
            earnedCreatorIMD += creatorShare;
            earnedVaultIMD += fee - creatorShare;
        } else {
            uint256 burned = fee * 50 / 100;
            earnedBurnSI += burned;
            earnedVaultSI += fee - burned;
        }
        assertFalse(imd.reentrySucceeded(), "payout reentry succeeded");
        ++swaps;
    }

    function _limit(bool zeroForOne, bool limitedPrice) private view returns (uint160) {
        if (!limitedPrice) return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint160 distance = price / 100_000;
        return zeroForOne ? price - distance : price + distance;
    }

    function _debt(uint256 selected) private view returns (address token, address recipient) {
        selected %= 4;
        token = selected < 2 ? address(si) : address(imd);
        recipient = selected % 2 == 0 ? address(vault) : (selected == 1 ? DEAD : creator);
    }

    function _stateDigest(address actor) private view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        bytes32 balances = keccak256(
            abi.encode(
                si.balanceOf(actor),
                imd.balanceOf(actor),
                si.balanceOf(address(manager)),
                imd.balanceOf(address(manager)),
                vault.totalSILocked(),
                vault.totalSIBurned(),
                vault.totalIMDHeld(),
                imd.balanceOf(creator)
            )
        );
        bytes32 debts = keccak256(
            abi.encode(
                hook.pending(address(si), address(vault)),
                hook.pending(address(si), DEAD),
                hook.pending(address(imd), address(vault)),
                hook.pending(address(imd), creator)
            )
        );
        return keccak256(
            abi.encode(
                price,
                tick,
                balances,
                debts,
                manager.balanceOf(address(hook), uint256(uint160(address(si)))),
                manager.balanceOf(address(hook), uint256(uint160(address(imd))))
            )
        );
    }
}

abstract contract SIFeeAccountingInvariantBase is SIIntegrationFixture {
    SIFeeSequenceHandler internal handler;

    function _siFirst() internal pure virtual returns (bool);

    function setUp() public {
        _deploySystem(_siFirst());
        handler = new SIFeeSequenceHandler(hook, router, key);
        for (uint256 i; i < 3; ++i) {
            _fund(handler.actors(i), 1_000_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.roundTrip.selector;
        selectors[2] = handler.setPayoutBehavior.selector;
        selectors[3] = handler.flush.selector;
        selectors[4] = handler.donateSI.selector;
        selectors[5] = handler.rejectedSwap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // Reach deferred fees before random calls, then leave retries and recovery to the sequence.
        handler.setPayoutBehavior(uint256(AdversarialIMD.Mode.RevertTransfer), false);
        handler.swap(0, 1000 ether, true, false, false);
        handler.swap(1, 1000 ether, false, false, false);
        assertGt(hook.pending(address(imd), address(vault)), 0);
    }

    function invariant_feesArePaidOrRemainOwedToExactlyTheIntendedRecipient() public view {
        assertEq(vault.totalIMDHeld() + hook.pending(address(imd), address(vault)), handler.earnedVaultIMD());
        assertEq(imd.balanceOf(CREATOR) + hook.pending(address(imd), CREATOR), handler.earnedCreatorIMD());
        assertEq(
            vault.totalSILocked() + hook.pending(address(si), address(vault)),
            handler.earnedVaultSI() + handler.donatedVaultSI()
        );
        assertEq(
            vault.totalSIBurned() + hook.pending(address(si), DEAD), handler.earnedBurnSI() + handler.donatedBurnSI()
        );
        assertEq(si.balanceOf(CREATOR), 0);
        assertEq(imd.balanceOf(DEAD), 0);
    }

    function invariant_deferredFeesAreFullyBackedAndRouterRetainsNoFunds() public view {
        _checkBacking(address(si), DEAD);
        _checkBacking(address(imd), CREATOR);
        assertEq(si.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(si.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(si.allowance(address(vault), address(router)), 0);
        assertEq(imd.allowance(address(vault), address(router)), 0);
        assertEq(hook.FEE_BPS(), 200);
        assertEq(hook.creatorReceiver(), CREATOR);
        assertEq(address(hook.vault()), address(vault));
    }

    function invariant_allTokensAreConservedAcrossTradersPoolAndSinks() public view {
        _checkSupply(IERC20(address(si)));
        _checkSupply(IERC20(address(imd)));
    }

    function afterInvariant() public {
        // A recovered recipient can collect every remaining debt exactly once after any sequence.
        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        imd.setMode(CREATOR, AdversarialIMD.Mode.Normal);
        for (uint256 i; i < 4; ++i) {
            handler.flush(i, type(uint256).max, i);
        }
        assertEq(hook.pending(address(si), address(vault)), 0);
        assertEq(hook.pending(address(si), DEAD), 0);
        assertEq(hook.pending(address(imd), address(vault)), 0);
        assertEq(hook.pending(address(imd), CREATOR), 0);
        invariant_feesArePaidOrRemainOwedToExactlyTheIntendedRecipient();
        invariant_deferredFeesAreFullyBackedAndRouterRetainsNoFunds();
        invariant_allTokensAreConservedAcrossTradersPoolAndSinks();
    }

    function test_sequenceWitnessIncludesFailurePartialFillRecoveryAndRoundTrip() public {
        handler.flush(2, 1 ether, 2);
        assertEq(handler.failedFlushes(), 1);
        handler.swap(2, 1000 ether, true, false, true);
        handler.swap(0, 100 ether, false, true, true);
        assertGt(handler.partialFills(), 0);
        handler.setPayoutBehavior(uint256(AdversarialIMD.Mode.Normal), false);
        handler.flush(2, type(uint256).max, 1);
        assertEq(handler.successfulFlushes(), 1);
        handler.roundTrip(1, 300 ether);
        handler.rejectedSwap(0, 10 ether, true, true);
        handler.rejectedSwap(2, 10 ether, false, false);
        assertEq(handler.rejectedSwaps(), 2);
        handler.donateSI(0, 1 ether, false);
        handler.donateSI(1, 1 ether, true);
        afterInvariant();
    }

    function _checkBacking(address token, address other) private view {
        uint256 debt = hook.pending(token, address(vault)) + hook.pending(token, other);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(token))), debt);
        assertGe(IERC20(token).balanceOf(address(manager)), debt);
        assertEq(manager.balanceOf(address(router), uint256(uint160(token))), 0);
    }

    function _checkSupply(IERC20 token) private view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(vault)) + token.balanceOf(DEAD) + token.balanceOf(CREATOR)
            + token.balanceOf(address(router)) + token.balanceOf(address(hook));
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SIAsCurrencyZeroInvariantTest is SIFeeAccountingInvariantBase {
    function _siFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SIAsCurrencyOneInvariantTest is SIFeeAccountingInvariantBase {
    function _siFirst() internal pure override returns (bool) {
        return false;
    }
}
