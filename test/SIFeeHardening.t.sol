// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIIntegrationFixture} from "./helpers/SIIntegrationFixture.sol";
import {AdversarialIMD} from "./mocks/AdversarialIMD.sol";
import {SIFeeHook} from "src/SIFeeHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SIFeeHardeningTest is SIIntegrationFixture {
    address private constant TRADER = address(0xB0B);

    function setUp() public {
        _deploySystem(true);
        _fund(TRADER, 10_000 ether);
    }

    function test_trueReturnWithoutPaymentCannotDestroyRecipientEntitlements() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.NoTransfer);
        imd.setMode(CREATOR, AdversarialIMD.Mode.TaxedTransfer);
        uint256 supply = imd.totalSupply();
        _buy();
        assertEq(vault.totalIMDHeld(), 0);
        assertEq(imd.balanceOf(CREATOR), 0);
        assertEq(imd.totalSupply(), supply, "tax must roll back along with failed delivery");
        _assertDebts(16 ether, 4 ether);

        assertFalse(hook.flush(address(imd), address(vault), 16 ether));
        assertFalse(hook.flush(address(imd), CREATOR, 4 ether));
        _assertDebts(16 ether, 4 ether);
        assertEq(imd.totalSupply(), supply);

        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        imd.setMode(CREATOR, AdversarialIMD.Mode.Normal);
        vm.prank(address(0x1234));
        assertTrue(hook.flush(address(imd), address(vault), 16 ether));
        assertTrue(hook.flush(address(imd), CREATOR, 4 ether));
        assertEq(vault.totalIMDHeld(), 16 ether);
        assertEq(imd.balanceOf(CREATOR), 4 ether);
        _assertDebts(0, 0);
    }

    function test_bothPayoutsCanExhaustGasWithoutBlockingBuyOrLaterSell() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.GasGrief);
        imd.setMode(CREATOR, AdversarialIMD.Mode.GasGrief);
        _buy();
        _assertDebts(16 ether, 4 ether);
        vm.prank(TRADER);
        router.swap(
            key, SwapParams(true, -1000 ether, TickMath.MIN_SQRT_PRICE + 1), 1000 ether, 1, TRADER, block.timestamp
        );
        assertEq(vault.totalSILocked(), 10 ether);
        assertEq(vault.totalSIBurned(), 10 ether);
        _assertDebts(16 ether, 4 ether);
    }

    function test_gasGriefRetryIsBoundedReturnsFalseAndReleasesGuard() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.GasGrief);
        _buy();
        uint256 gasBefore = gasleft();
        assertFalse(hook.flush{gas: 1_000_000}(address(imd), address(vault), 16 ether));
        assertLt(gasBefore - gasleft(), hook.FLUSH_GAS() + 100_000);
        _assertDebts(16 ether, 0);
        _buy();
        _assertDebts(32 ether, 0);
        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        assertTrue(hook.flush(address(imd), address(vault), 32 ether));
        assertEq(vault.totalIMDHeld(), 32 ether);
        _assertDebts(0, 0);
    }

    function test_insufficientRetryGasDefersWithoutLosingDebt() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.RevertTransfer);
        _buy();
        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        assertFalse(hook.flush{gas: 200_000}(address(imd), address(vault), 16 ether));
        _assertDebts(16 ether, 0);
        assertTrue(hook.flush(address(imd), address(vault), 16 ether));
        _assertDebts(0, 0);
    }

    function test_retryReturnBombLeavesDebtBackedAndCanRecover() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.ReturnBomb);
        _buy();
        assertFalse(hook.flush{gas: 400_000}(address(imd), address(vault), 16 ether));
        _assertDebts(16 ether, 0);
        imd.setMode(address(vault), AdversarialIMD.Mode.Normal);
        assertTrue(hook.flush(address(imd), address(vault), 16 ether));
        assertEq(vault.totalIMDHeld(), 16 ether);
        _assertDebts(0, 0);
    }

    function test_lowGasSwapDefersPayoutsAndStillChargesTheFixedFee() public {
        vm.prank(TRADER);
        BalanceDelta delta = router.swap{gas: 350_000}(
            key, SwapParams(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1), 1000 ether, 1, TRADER, block.timestamp
        );
        assertEq(delta.amount1(), -1000 ether);
        assertGt(delta.amount0(), 0);
        assertGt(hook.pending(address(imd), address(vault)) + hook.pending(address(imd), CREATOR), 0);
        assertEq(vault.totalIMDHeld() + hook.pending(address(imd), address(vault)), 16 ether);
        assertEq(imd.balanceOf(CREATOR) + hook.pending(address(imd), CREATOR), 4 ether);
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(imd)))),
            hook.pending(address(imd), address(vault)) + hook.pending(address(imd), CREATOR)
        );
    }

    function test_retryReentryCannotStealOtherDebtOrDoublePay() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.RevertTransfer);
        imd.setMode(CREATOR, AdversarialIMD.Mode.RevertTransfer);
        _buy();
        imd.setMode(address(vault), AdversarialIMD.Mode.Reenter);
        imd.setReentry(address(hook), abi.encodeCall(hook.flush, (address(imd), CREATOR, 4 ether)));
        assertTrue(hook.flush(address(imd), address(vault), 16 ether));
        assertTrue(imd.reentryAttempted());
        assertFalse(imd.reentrySucceeded());
        assertEq(vault.totalIMDHeld(), 16 ether);
        _assertDebts(0, 4 ether);
        vm.expectRevert(SIFeeHook.InvalidAmount.selector);
        hook.flush(address(imd), address(vault), 16 ether);
    }

    function test_creatorCannotBeAProtocolOrSinkAddress() public {
        address[6] memory invalid = [address(manager), address(vault), address(router), address(si), address(imd), DEAD];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(SIFeeHook.InvalidConfiguration.selector);
            new SIFeeHook(manager, address(si), address(imd), vault, invalid[i], address(router));
        }
    }

    function test_deployerAndStrangerCannotChangeFeesPauseUpgradeOrWithdraw() public {
        imd.setMode(address(vault), AdversarialIMD.Mode.RevertTransfer);
        _buy();
        bytes[10] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("initializer()"),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("setCreatorReceiver(address)", TRADER),
            abi.encodeWithSignature("transferOwnership(address)", TRADER),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("upgradeTo(address)", TRADER),
            abi.encodeWithSignature("withdraw(address,uint256)", address(imd), 16 ether),
            abi.encodeWithSignature("emergencyWithdraw(address)", TRADER)
        ];
        for (uint256 actor; actor < 2; ++actor) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(actor == 0 ? address(this) : TRADER);
                (bool success,) = address(hook).call(calls[i]);
                assertFalse(success);
            }
        }
        assertEq(hook.FEE_BPS(), 200);
        assertEq(hook.creatorReceiver(), CREATOR);
        _assertDebts(16 ether, 0);
        _buy();
        _assertDebts(32 ether, 0);
    }

    function _buy() private {
        uint256 beforeBalance = imd.balanceOf(TRADER);
        vm.prank(TRADER);
        BalanceDelta delta = router.swap(
            key, SwapParams(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1), 1000 ether, 1, TRADER, block.timestamp
        );
        assertEq(beforeBalance - imd.balanceOf(TRADER), 1000 ether);
        assertEq(delta.amount1(), -1000 ether);
        assertGt(delta.amount0(), 0);
    }

    function _assertDebts(uint256 toVault, uint256 toCreator) private view {
        assertEq(hook.pending(address(imd), address(vault)), toVault);
        assertEq(hook.pending(address(imd), CREATOR), toCreator);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(imd)))), toVault + toCreator);
    }
}
