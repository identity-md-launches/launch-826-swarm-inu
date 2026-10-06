// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {SICommunityVault} from "src/SICommunityVault.sol";

contract TokenVaultHandler is Test {
    SwarmInu public immutable si;
    SwarmInu public immutable imd;
    SICommunityVault public immutable vault;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xD00D)];
    mapping(address => mapping(address => uint256)) public expectedBalance;
    mapping(address => mapping(address => mapping(address => uint256))) public expectedAllowance;
    uint256 public transfers;
    uint256 public rejectedCalls;
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant DEAD = address(0xdEaD);

    constructor() {
        si = new SwarmInu();
        imd = new SwarmInu();
        vault = new SICommunityVault(address(si), address(imd));
        for (uint256 i; i < actors.length; ++i) {
            si.transfer(actors[i], SUPPLY / 4);
            imd.transfer(actors[i], SUPPLY / 4);
            expectedBalance[address(si)][actors[i]] = SUPPLY / 4;
            expectedBalance[address(imd)][actors[i]] = SUPPLY / 4;
        }
    }

    function transfer(uint256 who, uint256 destination, uint256 rawAmount, bool pair) public {
        SwarmInu token = pair ? imd : si;
        address from = actors[who % 4];
        address to = _recipient(destination);
        uint256 amount = bound(rawAmount, 0, expectedBalance[address(token)][from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(token, from, to, amount);
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool pair) public {
        SwarmInu token = pair ? imd : si;
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[address(token)][owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 destination, uint256 raw, bool pair) public {
        SwarmInu token = pair ? imd : si;
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = _recipient(destination);
        uint256 allowed = expectedAllowance[address(token)][owner][spender];
        uint256 maximum = expectedBalance[address(token)][owner];
        if (allowed < maximum) maximum = allowed;
        uint256 amount = bound(raw, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[address(token)][owner][spender] -= amount;
        _move(token, owner, to, amount);
        ++transfers;
    }

    function invalidTransfer(uint256 seed, uint256 kind, bool pair) public {
        SwarmInu token = pair ? imd : si;
        address actor = actors[seed % 4];
        uint256 balance = expectedBalance[address(token)][actor];
        if (kind % 3 == 0) {
            vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(actor);
            token.transfer(address(0), 0);
        } else if (kind % 3 == 1) {
            vm.expectRevert(
                abi.encodeWithSelector(SwarmInu.ERC20InsufficientBalance.selector, actor, balance, balance + 1)
            );
            vm.prank(actor);
            token.transfer(actors[(seed % 4 + 1) % 4], balance + 1);
        } else {
            // Even an arbitrary holder cannot spend a permanently locked vault balance.
            vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InsufficientAllowance.selector, actor, 0, 1));
            vm.prank(actor);
            token.transferFrom(address(vault), actor, 1);
        }
        ++rejectedCalls;
    }

    function revokeAndAttemptSpend(uint256 ownerSeed, uint256 spenderSeed, bool pair) public {
        SwarmInu token = pair ? imd : si;
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        token.approve(spender, 0);
        expectedAllowance[address(token)][owner][spender] = 0;
        vm.expectRevert(abi.encodeWithSelector(SwarmInu.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, spender, 1);
        ++rejectedCalls;
    }

    function attemptEscape(uint256 seed, uint256 kind, uint256 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 3650 days));
        address actor = actors[seed % 4];
        bytes[6] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", address(si), type(uint256).max),
            abi.encodeWithSignature("claim()"),
            abi.encodeWithSignature("release()"),
            abi.encodeWithSignature("approve(address,uint256)", actor, type(uint256).max),
            abi.encodeWithSignature("execute(address,bytes)", address(si), abi.encodeCall(si.transfer, (actor, 1))),
            abi.encodeWithSignature("redeem(uint256,address,address)", 1, actor, address(vault))
        ];
        vm.prank(actor);
        (bool ok,) = address(vault).call(calls[kind % calls.length]);
        assertFalse(ok, "vault exposes an exit or approval");
        ++rejectedCalls;
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 selected = seed % 6;
        if (selected < 4) return actors[selected];
        return selected == 4 ? address(vault) : DEAD;
    }

    function _move(SwarmInu token, address from, address to, uint256 amount) private {
        expectedBalance[address(token)][from] -= amount;
        expectedBalance[address(token)][to] += amount;
    }
}

/// @dev Exact ledger conservation and permanent custody are promises of this token/vault.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenVaultInvariantTest is Test {
    TokenVaultHandler internal handler;

    function setUp() public {
        handler = new TokenVaultHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.invalidTransfer.selector;
        selectors[4] = handler.revokeAndAttemptSpend.selector;
        selectors[5] = handler.attemptEscape.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // Seed both permanent sinks so their conservation checks are never empty.
        handler.transfer(0, 4, 1 ether, false);
        handler.transfer(1, 4, 1 ether, true);
        handler.transfer(2, 5, 1 ether, false);
    }

    function invariant_balancesAndAllowancesMatchIndependentLedger() public view {
        _checkToken(handler.si());
        _checkToken(handler.imd());
    }

    function invariant_vaultViewsIncludeAllDonationsAndBurnsForever() public view {
        SICommunityVault vault = handler.vault();
        assertEq(vault.totalSILocked(), handler.expectedBalance(address(handler.si()), address(vault)));
        assertEq(vault.totalIMDHeld(), handler.expectedBalance(address(handler.imd()), address(vault)));
        assertEq(vault.totalSIBurned(), handler.expectedBalance(address(handler.si()), address(0xdEaD)));
    }

    function test_handlerExercisesFullBalanceInfiniteApprovalAndRejection() public {
        uint256 balance = handler.si().balanceOf(handler.actors(0));
        handler.approve(0, 1, type(uint256).max, false);
        handler.transferFrom(0, 1, 0, type(uint256).max, false); // Full self-transfer.
        assertEq(handler.si().balanceOf(handler.actors(0)), balance);
        handler.transferFrom(0, 1, 4, type(uint256).max, false);
        assertEq(handler.si().balanceOf(handler.actors(0)), 0);
        assertEq(handler.si().allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        handler.revokeAndAttemptSpend(0, 1, false);
        handler.invalidTransfer(0, 1, false);
        handler.attemptEscape(1, 0, 3650 days);
        invariant_balancesAndAllowancesMatchIndependentLedger();
        invariant_vaultViewsIncludeAllDonationsAndBurnsForever();
        assertEq(handler.rejectedCalls(), 3);
    }

    function _checkToken(SwarmInu token) private view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(address(token), actor));
            sum += balance;
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(address(token), actor, spender));
                assertEq(token.allowance(address(handler.vault()), spender), 0);
                assertEq(token.allowance(address(0xdEaD), spender), 0);
            }
        }
        address vault = address(handler.vault());
        assertEq(token.balanceOf(vault), handler.expectedBalance(address(token), vault));
        assertEq(token.balanceOf(address(0xdEaD)), handler.expectedBalance(address(token), address(0xdEaD)));
        sum += token.balanceOf(vault) + token.balanceOf(address(0xdEaD));
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
