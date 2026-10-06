// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwarmInu} from "src/SwarmInu.sol";
import {SICommunityVault} from "src/SICommunityVault.sol";
import {SIFeeHook} from "src/SIFeeHook.sol";
import {SISwapRouter} from "src/SISwapRouter.sol";
import {LaunchLiquidity} from "src/LaunchLiquidity.sol";
import {AdversarialIMD} from "../mocks/AdversarialIMD.sol";

/// @dev Deploys the actual v4 manager and production contracts entirely offline.
abstract contract SIIntegrationFixture is Test, IUnlockCallback {
    SwarmInu internal si;
    AdversarialIMD internal imd;
    PoolManager internal manager;
    SICommunityVault internal vault;
    SIFeeHook internal hook;
    SISwapRouter internal router;
    PoolKey internal key;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant DEAD = address(0xdEaD);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function _deploySystem(bool siFirst) internal {
        si = new SwarmInu();
        AdversarialIMD template = new AdversarialIMD();
        address pairAt = address(uint160(address(si)) + 1);
        if (!siFirst) pairAt = address(uint160(address(si)) - 1);
        vm.etch(pairAt, address(template).code);
        imd = AdversarialIMD(pairAt);
        imd.mint(address(this), SUPPLY);
        manager = new PoolManager(address(this));
        router = new SISwapRouter(manager);
        vault = new SICommunityVault(address(si), address(imd));
        bytes32 hash = keccak256(
            abi.encodePacked(
                type(SIFeeHook).creationCode,
                abi.encode(manager, address(si), address(imd), vault, CREATOR, address(router))
            )
        );
        for (uint256 nonce;; ++nonce) {
            bytes32 salt = bytes32(nonce);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & 0x3fff != 0x20cc) continue;
            hook = new SIFeeHook{salt: salt}(manager, address(si), address(imd), vault, CREATOR, address(router));
            break;
        }
        key = PoolKey(
            Currency.wrap(siFirst ? address(si) : address(imd)),
            Currency.wrap(siFirst ? address(imd) : address(si)),
            0,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, uint160(1 << 96));
        manager.unlock(abi.encode(LaunchLiquidity.Seed(key, -60000, 60000, 1_000_000 ether)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "fixture: manager only");
        LaunchLiquidity.settleSeed(manager, data);
        return "";
    }

    function _fund(address actor, uint256 amount) internal {
        si.transfer(actor, amount);
        imd.transfer(actor, amount);
        vm.startPrank(actor);
        si.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }
}
