// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Compatibility helper for the network's token-only launch harness.
/// @dev This guard does not collect SI fees. Production SI/IMD must use SI's fee hook.
contract PoolInitializationGuard {
    error InvalidConfiguration();
    error Unauthorized();

    address public immutable poolManager;
    address public immutable initializer;

    constructor(address manager) {
        if (manager == address(0) || !HookFlags.matches(address(this), HookFlags.BEFORE_INITIALIZE)) {
            revert InvalidConfiguration();
        }
        poolManager = manager;
        initializer = msg.sender;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != poolManager || sender != initializer) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }
}
