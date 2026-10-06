// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {SICommunityVault} from "../src/SICommunityVault.sol";

contract TokenVaultTest is Test {
    SwarmInu internal token;
    SwarmInu internal pair;
    SICommunityVault internal vault;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new SwarmInu();
        pair = new SwarmInu();
        vault = new SICommunityVault(address(token), address(pair));
    }

    function test_metadataAndConstructorMint() public {
        assertEq(token.name(), "Swarminu.xyz");
        assertEq(token.symbol(), "SI");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        SwarmInu another = new SwarmInu();
        assertEq(another.balanceOf(ALICE), SUPPLY);
        assertEq(another.balanceOf(address(this)), 0);
    }

    function test_zeroAndSelfTransfers() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), ALICE, 0);
        assertTrue(token.transfer(ALICE, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferConservesSupplyAndDeliversExactAmount(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_allowanceConsumptionAndRevocation(uint256 approved, uint256 spent) public {
        approved = bound(approved, 0, SUPPLY);
        spent = bound(spent, 0, approved);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), ALICE, approved);
        assertTrue(token.approve(ALICE, approved));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, spent));
        assertEq(token.allowance(address(this), ALICE), approved - spent);
        assertEq(token.balanceOf(BOB), spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
        assertTrue(token.approve(ALICE, 0));
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_infiniteAllowanceStaysInfinite() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, SUPPLY);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), SUPPLY);
    }

    function test_rejectedTransfersPreserveBalancesAndAllowance() public {
        token.approve(ALICE, 123);
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(address(this), address(0), 123);
        assertEq(token.allowance(address(this), ALICE), 123);
        assertEq(token.balanceOf(address(this)), SUPPLY);

        vm.prank(BOB);
        token.approve(ALICE, 123);
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InsufficientBalance.selector, BOB, 0, 123));
        vm.prank(ALICE);
        token.transferFrom(BOB, ALICE, 123);
        assertEq(token.allowance(BOB, ALICE), 123);

        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_invalidZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function test_noMintOrHolderControl() public {
        token.transfer(ALICE, 100 ether);
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", BOB, SUPPLY),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", ALICE),
            abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 100 ether),
            abi.encodeWithSignature("seize(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", BOB)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function test_vaultDirectDonationsAndBurnViews() public {
        assertEq(address(vault.si()), address(token));
        assertEq(address(vault.imd()), address(pair));
        assertEq(vault.totalIMDHeld(), 0);
        assertEq(vault.totalSILocked(), 0);
        assertEq(vault.totalSIBurned(), 0);
        token.transfer(address(vault), 100 ether);
        pair.transfer(address(vault), 200 ether);
        token.transfer(vault.DEAD(), 50 ether);
        assertEq(vault.totalSILocked(), 100 ether);
        assertEq(vault.totalIMDHeld(), 200 ether);
        assertEq(vault.totalSIBurned(), 50 ether);
        assertEq(token.totalSupply(), SUPPLY);

        token.transfer(ALICE, 7 ether);
        vm.prank(ALICE);
        token.transfer(address(vault), 7 ether);
        assertEq(vault.totalSILocked(), 107 ether);
    }

    function test_vaultRejectsInvalidTokenConfiguration() public {
        vm.expectRevert(SICommunityVault.InvalidTokens.selector);
        new SICommunityVault(address(0), address(pair));
        vm.expectRevert(SICommunityVault.InvalidTokens.selector);
        new SICommunityVault(address(token), address(0));
        vm.expectRevert(SICommunityVault.InvalidTokens.selector);
        new SICommunityVault(address(token), address(token));
        vm.expectRevert(SICommunityVault.InvalidTokens.selector);
        new SICommunityVault(ALICE, address(pair));
    }

    function test_vaultHasNoExitOrApprovalAndCannotBeDrainedByDeployer() public {
        token.transfer(address(vault), 100 ether);
        pair.transfer(address(vault), 200 ether);
        bytes[7] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", address(token), 100 ether),
            abi.encodeWithSignature("release()"),
            abi.encodeWithSignature("redeem(uint256,address,address)", 100 ether, ALICE, address(vault)),
            abi.encodeWithSignature("claim()"),
            abi.encodeWithSignature("approve(address,uint256)", ALICE, type(uint256).max),
            abi.encodeWithSignature(
                "execute(address,bytes)", address(token), abi.encodeCall(token.transfer, (ALICE, 100 ether))
            ),
            abi.encodeWithSignature("transferOwnership(address)", ALICE)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(vault).call(calls[i]);
            assertFalse(success);
        }
        vm.expectRevert(
            abi.encodeWithSelector(SwarmInu.ERC20InsufficientAllowance.selector, address(this), 0, 100 ether)
        );
        token.transferFrom(address(vault), ALICE, 100 ether);
        assertEq(token.allowance(address(vault), address(this)), 0);
        assertEq(vault.totalSILocked(), 100 ether);
        assertEq(vault.totalIMDHeld(), 200 ether);
    }
}
