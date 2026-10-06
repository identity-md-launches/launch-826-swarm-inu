// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Single-pool ERC20 router that consumes input-fee refund claims from SI's hook.
/// @dev The caller approves this router for the input token. Each swap settles directly between
/// the caller, PoolManager and recipient. No approvals, custodial balances or withdrawal role exist.
contract SISwapRouter is IUnlockCallback {
    error InvalidConfiguration();
    error DeadlineExpired();
    error ReentrantSwap();
    error UnauthorizedCallback();
    error InvalidSwapDelta();
    error InputLimitExceeded();
    error OutputLimitNotMet();
    error TokenTransferFailed();
    error TokenSettlementMismatch();

    IPoolManager public immutable poolManager;
    address private activePayer;

    struct Request {
        PoolKey key;
        SwapParams params;
        uint256 maxInput;
        uint256 minOutput;
        address recipient;
    }

    event SwapExecuted(
        address indexed payer,
        address indexed recipient,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 inputFeeRefund
    );

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_).code.length == 0) revert InvalidConfiguration();
        poolManager = poolManager_;
    }

    /// @notice Swap with caller-selected input/output limits and an inclusive deadline.
    /// @return delta Actual amounts settled, including the fee and any partial-fill fee refund.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 maxInput,
        uint256 minOutput,
        address recipient,
        uint256 deadline
    ) external returns (BalanceDelta delta) {
        if (activePayer != address(0)) revert ReentrantSwap();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(poolManager)
                || Currency.unwrap(key.currency0).code.length == 0 || Currency.unwrap(key.currency1).code.length == 0
        ) revert InvalidConfiguration();

        activePayer = msg.sender;
        delta = abi.decode(
            poolManager.unlock(abi.encode(Request(key, params, maxInput, minOutput, recipient))), (BalanceDelta)
        );
        activePayer = address(0);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address payer = activePayer;
        if (msg.sender != address(poolManager) || payer == address(0)) revert UnauthorizedCallback();
        Request memory request = abi.decode(data, (Request));
        Currency input = request.params.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.params.zeroForOne ? request.key.currency1 : request.key.currency0;
        uint256 inputId = input.toId();
        uint256 claimsBefore = poolManager.balanceOf(address(this), inputId);
        BalanceDelta delta = poolManager.swap(request.key, request.params, "");
        uint256 refund = poolManager.balanceOf(address(this), inputId) - claimsBefore;

        int256 inputDelta = request.params.zeroForOne ? delta.amount0() : delta.amount1();
        int256 outputDelta = request.params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta > 0 || outputDelta < 0 || refund > uint256(-inputDelta)) revert InvalidSwapDelta();
        if (refund != 0) {
            // The hook mints only the excess reserved fee. Burning it credits this router's
            // transient input balance, so its caller pays precisely the fee on the actual fill.
            poolManager.burn(address(this), inputId, refund);
            inputDelta += int256(refund);
            delta = request.params.zeroForOne
                ? toBalanceDelta(int128(inputDelta), int128(outputDelta))
                : toBalanceDelta(int128(outputDelta), int128(inputDelta));
        }

        uint256 inputAmount = uint256(-inputDelta);
        uint256 outputAmount = uint256(outputDelta);
        if (inputAmount > request.maxInput) revert InputLimitExceeded();
        if (outputAmount < request.minOutput) revert OutputLimitNotMet();

        if (inputAmount != 0) {
            poolManager.sync(input);
            _transferFrom(Currency.unwrap(input), payer, address(poolManager), inputAmount);
            if (poolManager.settle() != inputAmount) revert TokenSettlementMismatch();
        }
        if (outputAmount != 0) poolManager.take(output, request.recipient, outputAmount);

        emit SwapExecuted(payer, request.recipient, Currency.unwrap(input), inputAmount, outputAmount, refund);
        return abi.encode(delta);
    }

    function _transferFrom(address token, address payer, address recipient, uint256 amount) private {
        bytes memory callData = abi.encodeCall(IERC20.transferFrom, (payer, recipient, amount));
        bool success;
        uint256 returnSize;
        uint256 returned;
        assembly ("memory-safe") {
            let result := mload(0x40)
            success := call(gas(), token, 0, add(callData, 32), mload(callData), result, 32)
            returnSize := returndatasize()
            returned := mload(result)
        }
        if (!success || (returnSize != 0 && (returnSize < 32 || returned != 1))) revert TokenTransferFailed();
    }
}
