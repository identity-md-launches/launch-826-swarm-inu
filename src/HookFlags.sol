// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Uniswap v4 hook-address flag helpers used by deterministic launch tooling.
library HookFlags {
    uint160 internal constant ALL = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA = 1 << 2;

    function matches(address candidate, uint160 flags) internal pure returns (bool) {
        return uint160(candidate) & ALL == flags;
    }
}
