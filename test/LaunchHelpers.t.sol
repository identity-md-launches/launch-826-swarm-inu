// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LaunchLiquidity} from "../src/LaunchLiquidity.sol";
import {PoolInitializationGuard} from "../src/PoolInitializationGuard.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract LaunchHelperToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LaunchHelperRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function seed(LaunchLiquidity.Seed calldata value) external {
        manager.unlock(abi.encode(uint8(0), abi.encode(value)));
    }

    function swap(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(key, params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            LaunchLiquidity.settleSeed(manager, payload);
            return "";
        }
        (PoolKey memory key, SwapParams memory params) = abi.decode(payload, (PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        LaunchLiquidity.settle(manager, key.currency0, delta.amount0());
        LaunchLiquidity.settle(manager, key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

contract LaunchHelpersTest is Test {
    PoolManager private manager;
    LaunchHelperRouter private router;
    LaunchHelperToken private token0;
    LaunchHelperToken private token1;
    PoolKey private key;

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new LaunchHelperRouter(manager);
        LaunchHelperToken first = new LaunchHelperToken();
        LaunchHelperToken second = new LaunchHelperToken();
        (token0, token1) = address(first) < address(second) ? (first, second) : (second, first);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
    }

    function test_seedAndSwapSettleActualManagerBalances() public {
        token0.mint(address(router), 1e24);
        token1.mint(address(router), 1e24);
        router.seed(LaunchLiquidity.Seed(key, -120, 120, 1e24));
        uint256 before0 = token0.balanceOf(address(manager));
        uint256 before1 = token1.balanceOf(address(manager));
        assertGt(before0, 0);
        assertGt(before1, 0);

        BalanceDelta delta = router.swap(key, SwapParams(true, -1e18, 4_295_128_740));
        assertEq(delta.amount0(), -1e18);
        assertGt(delta.amount1(), 0);
        assertEq(token0.balanceOf(address(manager)), before0 + 1e18);
        assertEq(token1.balanceOf(address(manager)), before1 - uint128(delta.amount1()));
    }

    function test_nativeSeedAndSwapSettlement() public {
        PoolKey memory nativeKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token1)), 0, 60, IHooks(address(0)));
        manager.initialize(nativeKey, uint160(1 << 96));
        vm.deal(address(router), 100 ether);
        token1.mint(address(router), 100 ether);
        router.seed(LaunchLiquidity.Seed(nativeKey, -120, 120, 1000 ether));
        uint256 nativeBefore = address(manager).balance;
        BalanceDelta buy = router.swap(nativeKey, SwapParams(true, -1 ether, 4_295_128_740));
        assertEq(address(manager).balance, nativeBefore + 1 ether);
        assertGt(buy.amount1(), 0);
        BalanceDelta sell = router.swap(
            nativeKey,
            SwapParams(false, -int256(buy.amount1()), 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341)
        );
        assertGt(sell.amount0(), 0);
        assertEq(address(manager).balance, nativeBefore + 1 ether - uint128(sell.amount0()));
    }

    function test_seedFailsWithoutFundsAndLeavesPoolUnfunded() public {
        vm.expectRevert();
        router.seed(LaunchLiquidity.Seed(key, -120, 120, 1e24));
        assertEq(token0.balanceOf(address(manager)), 0);
        assertEq(token1.balanceOf(address(manager)), 0);
    }

    function test_emptySeedRejected() public {
        vm.expectRevert(LaunchLiquidity.EmptySeed.selector);
        router.seed(LaunchLiquidity.Seed(key, -120, 120, 0));
    }

    function test_guardAllowsOnlyDeployerInitializationThroughManager() public {
        PoolInitializationGuard guard = _deployGuard();
        assertEq(guard.initializer(), address(this));
        assertTrue(HookFlags.matches(address(guard), HookFlags.BEFORE_INITIALIZE));
        key.hooks = IHooks(address(guard));

        vm.expectRevert(PoolInitializationGuard.Unauthorized.selector);
        guard.beforeInitialize(address(this), key, uint160(1 << 96));

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        manager.initialize(key, uint160(1 << 96));

        manager.initialize(key, uint160(1 << 96));
    }

    function testFuzz_hookFlagsRejectAdditionalPermissions(uint160 prefix, uint160 flags) public pure {
        uint160 wanted = flags & HookFlags.ALL;
        address candidate = address((prefix & ~HookFlags.ALL) | wanted);
        assertTrue(HookFlags.matches(candidate, wanted));
        assertFalse(HookFlags.matches(candidate, wanted ^ 1));
    }

    function _deployGuard() private returns (PoolInitializationGuard guard) {
        bytes32 hash =
            keccak256(abi.encodePacked(type(PoolInitializationGuard).creationCode, abi.encode(address(manager))));
        for (uint256 i; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) {
                return new PoolInitializationGuard{salt: salt}(address(manager));
            }
        }
        revert("salt search exhausted");
    }
}
