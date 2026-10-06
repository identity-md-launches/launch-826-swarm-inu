// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SICommunityVault} from "./SICommunityVault.sol";

interface ISIRefundRouter {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Immutable 2% input-currency fee for a single SI/IMD pool.
/// @dev Unpaid distributions remain fully backed by ERC6909 claims, never change recipient,
/// and can be retried by anyone. No token swaps, approvals, admin, or withdrawal powers.
contract SIFeeHook is IUnlockCallback {
    uint256 public constant FEE_BPS = 200;
    uint160 public constant REQUIRED_FLAGS = 0x20cc;
    int24 public constant TICK_SPACING = 60;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant PAYOUT_GAS = 120_000;

    IPoolManager public immutable poolManager;
    address public immutable si;
    address public immutable imd;
    SICommunityVault public immutable vault;
    address public immutable creatorReceiver;
    address public immutable partialFillRouter;
    address public immutable initializer;
    mapping(address currency => mapping(address recipient => uint256 amount)) public pending;
    bool private swapping;
    bool private flushing;

    error InvalidConfiguration();
    error InvalidHookAddress();
    error OnlyPoolManager();
    error OnlySelf();
    error InvalidPool();
    error OnlyInitializer();
    error Reentrancy();
    error InvalidAmount();
    error PartialFillRequiresRouter();
    error InvalidCallback();

    event FeeAccrued(address indexed currency, uint256 fee);
    event PayoutDeferred(address indexed currency, address indexed recipient, uint256 amount);
    event PayoutDelivered(address indexed currency, address indexed recipient, uint256 amount);
    event InputRefund(address indexed router, address indexed currency, uint256 amount);

    constructor(
        IPoolManager manager_,
        address si_,
        address imd_,
        SICommunityVault vault_,
        address creatorReceiver_,
        address partialFillRouter_
    ) {
        if (
            address(manager_).code.length == 0 || si_.code.length == 0 || imd_.code.length == 0 || si_ == imd_
                || address(vault_).code.length == 0 || creatorReceiver_ == address(0)
                || partialFillRouter_.code.length == 0
        ) revert InvalidConfiguration();
        if (
            address(vault_.si()) != si_ || address(vault_.imd()) != imd_
                || address(ISIRefundRouter(partialFillRouter_).poolManager()) != address(manager_)
        ) revert InvalidConfiguration();
        if (uint160(address(this)) & 0x3fff != REQUIRED_FLAGS) revert InvalidHookAddress();
        poolManager = manager_;
        si = si_;
        imd = imd_;
        vault = vault_;
        creatorReceiver = creatorReceiver_;
        partialFillRouter = partialFillRouter_;
        initializer = msg.sender;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        if (sender != initializer) revert OnlyInitializer();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (swapping || flushing) revert Reentrancy();
        if (
            params.amountSpecified == 0 || params.amountSpecified < -int256(type(int128).max)
                || params.amountSpecified > int256(type(int128).max)
        ) revert InvalidAmount();
        swapping = true;
        // Reserve 2% of an exact-input budget before the core swap uses the other 98%.
        uint256 reserved = params.amountSpecified < 0 ? uint256(-params.amountSpecified) / 50 : 0;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(reserved)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        if (!swapping || flushing) revert InvalidCallback();
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (inputDelta > 0) revert InvalidAmount();
        uint256 netInput = uint256(-int256(inputDelta));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 fee = params.amountSpecified < 0
            ? _exactInputFee(sender, input, uint256(-params.amountSpecified), netInput)
            : netInput / 49;
        int128 returnedFee = params.amountSpecified > 0 ? int128(int256(fee)) : int128(0);
        _distribute(input, fee);
        swapping = false;
        return (IHooks.afterSwap.selector, returnedFee);
    }

    function _exactInputFee(address sender, Currency input, uint256 grossBudget, uint256 netInput)
        private
        returns (uint256 fee)
    {
        uint256 reserved = grossBudget / 50;
        if (netInput == grossBudget - reserved) return reserved;
        // Core afterSwap may only alter the unspecified (output) delta for exact input.
        // Refund claims let our router reduce its input debt without charging output tokens.
        if (sender != partialFillRouter) revert PartialFillRequiresRouter();
        fee = netInput / 49;
        uint256 refund = reserved - fee;
        if (refund != 0) {
            poolManager.mint(sender, input.toId(), refund);
            emit InputRefund(sender, Currency.unwrap(input), refund);
        }
    }

    /// @notice Retry up to `amount` of an existing fixed-recipient debt. Anyone may pay the gas.
    /// @return delivered False leaves all accounting unchanged, allowing a later retry.
    function flush(address currency, address recipient, uint256 amount) external returns (bool delivered) {
        if (swapping || flushing) revert Reentrancy();
        if (amount == 0 || amount > pending[currency][recipient] || amount > uint256(uint128(type(int128).max))) {
            revert InvalidAmount();
        }
        flushing = true;
        try poolManager.unlock(abi.encode(currency, recipient, amount)) returns (bytes memory) {
            delivered = true;
        } catch {
            emit PayoutDeferred(currency, recipient, amount);
        }
        flushing = false;
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!flushing || swapping) revert InvalidCallback();
        (address currency, address recipient, uint256 amount) = abi.decode(data, (address, address, uint256));
        _deliver(Currency.wrap(currency), recipient, amount);
        return "";
    }

    /// @dev External self-call provides an atomic rollback boundary for failed token transfers.
    function deliver(Currency currency, address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _deliver(currency, recipient, amount);
    }

    function _distribute(Currency currency, uint256 fee) private {
        if (fee == 0) return;
        poolManager.mint(address(this), currency.toId(), fee);
        address token = Currency.unwrap(currency);
        uint256 otherShare = token == imd ? fee / 5 : fee / 2;
        address other = token == imd ? creatorReceiver : DEAD;
        uint256 vaultShare = fee - otherShare;
        pending[token][address(vault)] += vaultShare;
        pending[token][other] += otherShare;
        emit FeeAccrued(token, fee);
        _tryDeliver(currency, address(vault), vaultShare);
        _tryDeliver(currency, other, otherShare);
    }

    function _tryDeliver(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        bool delivered = false;
        // Preserve ample gas for claim accounting even if a hostile token consumes the entire cap.
        if (gasleft() > PAYOUT_GAS + 150_000) {
            bytes memory callData = abi.encodeCall(this.deliver, (currency, recipient, amount));
            uint256 cap = PAYOUT_GAS;
            assembly ("memory-safe") {
                delivered := call(cap, address(), 0, add(callData, 32), mload(callData), 0, 0)
            }
        }
        if (!delivered) emit PayoutDeferred(Currency.unwrap(currency), recipient, amount);
    }

    function _deliver(Currency currency, address recipient, uint256 amount) private {
        pending[Currency.unwrap(currency)][recipient] -= amount;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        emit PayoutDelivered(Currency.unwrap(currency), recipient, amount);
    }

    function _checkPool(PoolKey calldata key) private view {
        (address c0, address c1) = si < imd ? (si, imd) : (imd, si);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != 0
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) {
            revert InvalidPool();
        }
    }
}
