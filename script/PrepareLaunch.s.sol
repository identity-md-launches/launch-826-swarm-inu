// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwarmInu} from "../src/SwarmInu.sol";
import {SICommunityVault} from "../src/SICommunityVault.sol";
import {SISwapRouter} from "../src/SISwapRouter.sol";
import {SIFeeHook} from "../src/SIFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Local, deterministic deployment planning. No environment, wallet, or broadcast access.
/// @dev Deploy the four initcodes through `factory` in token/vault/router/hook order. The factory
/// must initialize Plan.pool with this custom fee hook, never PoolInitializationGuard.
contract PrepareLaunch {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address public constant REMAINDER_TO = 0x66522f25035C3FAFd2c6D950a506FDa457E06344;
    uint160 private constant FEE_HOOK_FLAGS = 0x20cc;

    error InvalidParameters();
    error SaltSearchExhausted();
    error InvalidPrice();

    struct Deployment {
        bytes initCode;
        bytes32 salt;
        address predicted;
    }

    struct Plan {
        Deployment token;
        Deployment vault;
        Deployment router;
        Deployment hook;
        PoolKey pool;
        uint160 sqrtPriceX96;
        uint256 totalSupply;
        uint256 initialMarketCapWei;
        uint16 poolBps;
        uint16 swarmBps;
        uint16 remainderBps;
        address remainderTo;
    }

    /// @param imdDecimals Verified decimals of the actual IMD contract (0 through 36).
    /// @dev Addresses are explicit inputs and must be verified on the intended chain before launch.
    /// The hook salt search is bounded; changing factory or launch number gives a new search domain.
    function prepare(
        address factory,
        address manager,
        address imd,
        address creator,
        uint64 launchNumber,
        uint8 imdDecimals
    ) external pure returns (Plan memory plan) {
        if (
            factory == address(0) || manager == address(0) || imd == address(0) || creator == address(0)
                || imdDecimals > 36
        ) {
            revert InvalidParameters();
        }

        plan.token = _deployment(factory, type(SwarmInu).creationCode, bytes32(uint256(launchNumber)));
        if (plan.token.predicted == imd) revert InvalidParameters();
        plan.vault = _deployment(
            factory,
            abi.encodePacked(type(SICommunityVault).creationCode, abi.encode(plan.token.predicted, imd)),
            keccak256(abi.encode("SI_COMMUNITY_VAULT", launchNumber))
        );
        plan.router = _deployment(
            factory,
            abi.encodePacked(type(SISwapRouter).creationCode, abi.encode(IPoolManager(manager))),
            keccak256(abi.encode("SI_SWAP_ROUTER", launchNumber))
        );
        plan.hook.initCode = abi.encodePacked(
            type(SIFeeHook).creationCode,
            abi.encode(
                IPoolManager(manager),
                plan.token.predicted,
                imd,
                SICommunityVault(plan.vault.predicted),
                creator,
                plan.router.predicted
            )
        );
        (plan.hook.salt, plan.hook.predicted) = _mineHook(factory, keccak256(plan.hook.initCode), launchNumber);

        bool siIsZero = plan.token.predicted < imd;
        plan.pool = PoolKey(
            Currency.wrap(siIsZero ? plan.token.predicted : imd),
            Currency.wrap(siIsZero ? imd : plan.token.predicted),
            0,
            60,
            IHooks(plan.hook.predicted)
        );
        plan.totalSupply = SUPPLY;
        plan.initialMarketCapWei = 2500 * 10 ** uint256(imdDecimals);
        plan.sqrtPriceX96 =
            siIsZero ? _sqrtPrice(plan.initialMarketCapWei, SUPPLY) : _sqrtPrice(SUPPLY, plan.initialMarketCapWei);
        plan.poolBps = 8800;
        plan.swarmBps = 1000;
        plan.remainderBps = 200;
        plan.remainderTo = REMAINDER_TO;
    }

    function _deployment(address factory, bytes memory initCode, bytes32 salt)
        private
        pure
        returns (Deployment memory)
    {
        return Deployment(initCode, salt, _predict(factory, salt, keccak256(initCode)));
    }

    function _predict(address factory, bytes32 salt, bytes32 hash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, hash)))));
    }

    function _mineHook(address factory, bytes32 hash, uint64 launchNumber)
        private
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce; nonce < 1_000_000; ++nonce) {
            salt = keccak256(abi.encode("SI_FEE_HOOK", launchNumber, nonce));
            predicted = _predict(factory, salt, hash);
            if (HookFlags.matches(predicted, FEE_HOOK_FLAGS)) return (salt, predicted);
        }
        revert SaltSearchExhausted();
    }

    /// @dev Returns floor(sqrt(numerator / denominator) * 2^96), without a 256-bit Q192 intermediate.
    /// Allowed supply/cap bounds keep denominator * estimate below 2^256 throughout refinement.
    function _sqrtPrice(uint256 numerator, uint256 denominator) private pure returns (uint160) {
        uint256 estimate = (_sqrt(FullMath.mulDiv(numerator, 1 << 128, denominator)) + 1) << 32;
        while (true) {
            uint256 next = (estimate + FullMath.mulDiv(numerator, 1 << 192, denominator * estimate)) >> 1;
            if (next >= estimate) break;
            estimate = next;
        }
        if (estimate < TickMath.MIN_SQRT_PRICE || estimate >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();
        return uint160(estimate);
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;
        if (value < 4) return 1;
        result = value;
        uint256 next = (value >> 1) + 1;
        while (next < result) {
            result = next;
            next = (value / next + next) >> 1;
        }
    }
}
