// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {SICommunityVault} from "../src/SICommunityVault.sol";
import {SISwapRouter} from "../src/SISwapRouter.sol";
import {SIFeeHook} from "../src/SIFeeHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract PlanFactoryProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }

    function initialize(IPoolManager manager, PoolKey calldata pool, uint160 price) external {
        manager.initialize(pool, price);
    }
}

contract PrepareLaunchTest is Test {
    using StateLibrary for IPoolManager;

    PrepareLaunch private planner;
    PlanFactoryProbe private factory;
    PoolManager private manager;
    SwarmInu private imd;
    address private constant CREATOR = address(0xC0FFEE);

    function setUp() public {
        planner = new PrepareLaunch();
        factory = new PlanFactoryProbe();
        manager = new PoolManager(address(this));
        imd = new SwarmInu();
    }

    function test_planDeploysPredictedContractsAndPreservesSupply() public {
        PrepareLaunch.Plan memory plan =
            planner.prepare(address(factory), address(manager), address(imd), CREATOR, 42, 18);
        assertEq(plan.token.salt, bytes32(uint256(42)));
        assertEq(plan.totalSupply, 1_000_000_000 ether);
        assertEq(plan.initialMarketCapWei, 2500 ether);
        assertEq(uint256(plan.poolBps) + plan.swarmBps + plan.remainderBps, 10_000);
        assertEq(plan.poolBps, 8800);
        assertEq(plan.swarmBps, 1000);
        assertEq(plan.remainderBps, 200);
        assertEq(plan.remainderTo, 0x66522f25035C3FAFd2c6D950a506FDa457E06344);

        SwarmInu token = SwarmInu(factory.deploy(plan.token.initCode, plan.token.salt));
        assertEq(address(token), plan.token.predicted);
        assertEq(token.balanceOf(address(factory)), plan.totalSupply);

        SICommunityVault vault = SICommunityVault(factory.deploy(plan.vault.initCode, plan.vault.salt));
        SISwapRouter router = SISwapRouter(factory.deploy(plan.router.initCode, plan.router.salt));
        SIFeeHook hook = SIFeeHook(factory.deploy(plan.hook.initCode, plan.hook.salt));
        assertEq(address(vault), plan.vault.predicted);
        assertEq(address(router), plan.router.predicted);
        assertEq(address(hook), plan.hook.predicted);
        assertEq(uint160(address(hook)) & 0x3fff, 0x20cc);
        assertEq(hook.initializer(), address(factory));
        assertEq(hook.creatorReceiver(), CREATOR);
        assertEq(hook.partialFillRouter(), address(router));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.si(), address(token));
        assertEq(hook.imd(), address(imd));
        assertEq(address(hook.vault()), address(vault));
        assertEq(token.totalSupply(), plan.totalSupply);
        assertEq(token.balanceOf(address(factory)), plan.totalSupply);
        assertEq(vault.totalSILocked(), 0);

        assertEq(address(plan.pool.hooks), address(hook));
        assertEq(plan.pool.fee, 0);
        assertEq(plan.pool.tickSpacing, 60);
        factory.initialize(manager, plan.pool, plan.sqrtPriceX96);
        (uint160 actualPrice,,,) = IPoolManager(address(manager)).getSlot0(plan.pool.toId());
        assertEq(actualPrice, plan.sqrtPriceX96);
    }

    function test_pricesMatchIndependentIntegerReferenceForBothCurrencyOrders() public view {
        uint8[4] memory decimals = [uint8(0), 6, 18, 36];
        // Reference: Python math.isqrt((numerator << 192) // denominator).
        uint160[4] memory siZero = [
            uint160(125270724187523965),
            125270724187523965593,
            125270724187523965593206900,
            125270724187523965593206900784803161
        ];
        uint160[4] memory siOne = [
            uint160(50108289675009586237282760313921264616153),
            50108289675009586237282760313921264616,
            50108289675009586237282760313921,
            50108289675009586237282
        ];
        for (uint256 i; i < decimals.length; ++i) {
            PrepareLaunch.Plan memory highPair = planner.prepare(
                address(factory), address(manager), address(type(uint160).max), CREATOR, 42, decimals[i]
            );
            PrepareLaunch.Plan memory lowPair =
                planner.prepare(address(factory), address(manager), address(1), CREATOR, 42, decimals[i]);
            assertEq(Currency.unwrap(highPair.pool.currency0), highPair.token.predicted);
            assertEq(Currency.unwrap(lowPair.pool.currency1), lowPair.token.predicted);
            assertEq(highPair.sqrtPriceX96, siZero[i]);
            assertEq(lowPair.sqrtPriceX96, siOne[i]);
            assertEq(highPair.initialMarketCapWei, 2500 * 10 ** uint256(decimals[i]));
        }
    }

    function test_rejectsMissingAddressesAndUnsupportedDecimals() public {
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        planner.prepare(address(0), address(manager), address(imd), CREATOR, 42, 18);
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        planner.prepare(address(factory), address(0), address(imd), CREATOR, 42, 18);
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        planner.prepare(address(factory), address(manager), address(0), CREATOR, 42, 18);
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        planner.prepare(address(factory), address(manager), address(imd), address(0), 42, 18);
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        planner.prepare(address(factory), address(manager), address(imd), CREATOR, 42, 37);
    }
}
