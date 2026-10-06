// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Settlement helpers for a launch factory's authenticated unlock callback.
/// @dev The calling contract must authenticate PoolManager before entering these internal methods.
library LaunchLiquidity {
    error EmptySeed();

    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function settleSeed(IPoolManager manager, bytes memory data) internal {
        Seed memory seed = abi.decode(data, (Seed));
        if (seed.liquidity == 0) revert EmptySeed();
        (BalanceDelta delta,) = manager.modifyLiquidity(
            seed.key,
            ModifyLiquidityParams(seed.tickLower, seed.tickUpper, int256(uint256(seed.liquidity)), bytes32(0)),
            ""
        );
        settle(manager, seed.key.currency0, delta.amount0());
        settle(manager, seed.key.currency1, delta.amount1());
    }

    function settle(IPoolManager manager, Currency currency, int128 delta) internal {
        if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        } else if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                currency.transfer(address(manager), owed);
                manager.settle();
            }
        }
    }
}
