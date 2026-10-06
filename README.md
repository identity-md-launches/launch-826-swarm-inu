# Swarminu.xyz (SI) — Swarm Inu

SI is the INU for the IMD swarm. The ERC20 is a fixed-supply token; swap fees belong to a separate Uniswap v4 hook.

- Website: https://www.swarminu.xyz/
- Twitter: https://x.com/swarminu
- On-chain name: **Swarminu.xyz**; symbol: **SI**; decimals: **18**.
- Supply: **1,000,000,000 SI**, or **1000000000000000000000000000** minor units, minted once to the constructor's `msg.sender`.

The brief contains both “Swarminu.xyz” and “Swarm Inu” as token names. This implementation uses the first, structured token name on-chain and uses Swarm Inu as the project name. There is no mechanism to rename the deployed token.

## Contracts

| Source | Purpose |
| --- | --- |
| `src/SwarmInu.sol` | Plain ERC20. No owner, later minting, transfer tax, freeze, blacklist, burn authority, proxy, or upgrade. |
| `src/SICommunityVault.sol` | Permanent ERC20 sink. No outgoing transfer, approval, withdrawal, execution, redemption, or claim function. |
| `src/SIFeeHook.sol` | Immutable 2% input fee, fixed destinations, and failure-tolerant payouts. |
| `src/SISwapRouter.sol` | Direct caller-to-PoolManager settlement, slippage limits, and input-fee refunds for partial fills. |
| `script/PrepareLaunch.s.sol` | Local deployment planning with explicit arguments, CREATE2 addresses/salts, and initial price. No broadcasting or key access. |

`LaunchLiquidity`, `HookFlags`, and `PoolInitializationGuard` are compatibility helpers for the supplied launch checks. **The production pool must use `SIFeeHook` as `PoolKey.hooks`.** `PoolInitializationGuard` alone does not charge fees. The supplied protected test creates its own guard, so it establishes ERC20 launch compatibility, not fee-hook deployment correctness.

## Fees and permanent holdings

The supported pool has SI and the configured IMD ERC20, `fee = 0` (zero LP fee), and `tickSpacing = 60`. Its fee hook address must have low 14 bits `0x20cc`: before-initialize, before-swap, after-swap, and both swap delta permissions. Pool initialization is restricted to the hook's constructor deployer, normally the project factory. This address has no ongoing configuration or token powers.

| Trader input | Hook fee | Distribution |
| --- | --- | --- |
| IMD (buy SI) | 2% in IMD | 80% vault, 20% immutable creator receiver |
| SI (sell SI) | 2% in SI | 50% vault, 50% `0x000000000000000000000000000000000000dEaD` |

For a fully filled exact-input swap, the fee is `floor(grossInput / 50)` and the remaining input reaches the AMM. For exact-output swaps and partial exact-input fills, it is `floor(actualAmmInput / 49)`, so the fee is 2% of the gross amount paid, rounded down to token minor units. Tiny swaps can round to zero. The creator share is `floor(fee / 5)` on buys; the burn share is `floor(fee / 2)` on sells; the vault receives each split's rounding remainder. No output-token fees are charged. Exact-output routing can also fill partially at a price limit; set `minOutput` to the desired output if a complete fill is required.

Use **SISwapRouter for partial exact-input fills**. v4 only lets an after-swap callback change the unspecified currency. The hook therefore reserves the input fee before the swap and issues a claim for any unused fee to this router; the router burns that claim to reduce the input debt before collecting payment. Other routers work for full exact-input fills and exact-output swaps. A partial exact-input fill through another router reverts atomically with `PartialFillRequiresRouter`, instead of charging a fee on unused input. Routers must include the hook fee in their input limits. Fee logic does not inspect or trust caller-supplied hook data.

The hook first backs each fee with PoolManager ERC6909 claims. It attempts each distribution separately within a fixed gas allowance. A reverting, false-returning, malformed-returning, or gas-consuming recipient-specific token transfer leaves the unpaid amount in `pending(currency, recipient)` and keeps its backing claim. Transfers that mutate balances then return false are rolled back at the external self-call boundary. There is no alternate destination or administrator who can collect these claims.

Anyone can call `flush(currency, recipient, amount)` to retry an existing debt, including a partial amount. A failed retry returns false and leaves the debt intact. A successful retry burns the backing claim and transfers only to the recorded recipient. On a first buy into a single-sided pool, the manager may not yet hold IMD when the hook runs; fees then remain pending until the trader's input settles and somebody calls `flush`. Low available gas can also defer automatic payout. A keeper or UI should monitor `PayoutDeferred` and retry; retries earn no reward. A permanently blocked recipient leaves its fee claim pending permanently and does not disable swaps.

Vault views read actual balances:

- `totalIMDHeld()` includes all IMD donations and successfully delivered fees.
- `totalSILocked()` includes all SI donations and successfully delivered fees.
- `totalSIBurned()` is the SI balance of the dead address, including direct transfers by anyone.

Pending hook claims are not yet vault balances or completed burns. Sending SI to the dead address does **not** reduce ERC20 `totalSupply`. Anyone donates simply by transferring tokens to the vault; there are no shares or holder entitlements. Tokens accidentally sent to the hook/router, and unrelated tokens sent to the vault, have no rescue path.

## Deployment parameters and launch economics

No chain, verified PoolManager address, IMD address/decimals, or creator receiver was supplied. The literal `<YOUR_WALLET>` remains an unresolved deployment choice: supply a real nonzero address to the hook constructor. The remainder wallet below is not silently reused as creator receiver. All addresses in the upstream reference tables remain unverified; none are hardcoded as protocol deployments.

| Launch allocation | Share of total supply | SI |
| --- | --- | --- |
| Single-sided SI/IMD liquidity | 88% (`poolBps = 8800`) | 880,000,000 |
| Network MerkleDistributor allocation, performed by the factory | 10% | 100,000,000 |
| Remainder | 2% | 20,000,000 |

`remainderTo = 0x66522f25035C3FAFd2c6D950a506FDa457E06344`.

The **starting fully diluted market cap is 2500 IMD**, not an instruction to deposit 2500 IMD into the single-sided pool. `initialMarketCapWei = 2500 * 10**imdDecimals`. If IMD has 18 decimals this is `2500000000000000000000`. Opening human price is 0.0000025 IMD per SI. Minor-unit price must account for IMD's actual decimals and token address ordering:

```
SI = currency0: sqrtPriceX96 = floor(sqrt(initialMarketCapWei * 2**192 / totalSupply))
SI = currency1: sqrtPriceX96 = floor(sqrt(totalSupply * 2**192 / initialMarketCapWei))
```

The planner computes these values without floating point. These parameters do not automatically allocate tokens: the factory must actually forward the swarm share, initialize the correct pool, seed the SI allocation using the appropriate tick-aligned single-sided position, and transfer the remainder. Position tick bounds, liquidity quantity, LP custody, and any unused rounding dust remain factory/deployer responsibilities. No LP lock or LP withdrawal policy was specified, so this project does not claim that the liquidity position is permanently locked.

Deploy in dependency order:

1. `SwarmInu()` from the launch factory; the factory receives the entire supply.
2. `SICommunityVault(address si, address imd)`.
3. `SISwapRouter(IPoolManager manager)`.
4. `SIFeeHook(IPoolManager manager, address si, address imd, SICommunityVault vault, address creatorReceiver, address partialFillRouter)` using a mined CREATE2 salt.
5. Initialize and seed the pool through the same factory that deployed the hook, with `hooks = SIFeeHook`, zero LP fee, spacing 60, and the planned starting price.

The constructor verifies deployed token/manager/router code and matching vault/router configuration; those checks cannot establish that an arbitrary contract is the intended production implementation. The deployer must attest the actual code, addresses, constructor arguments, dependency order, and salts. The hook's trusted partial-fill router must be this project's `SISwapRouter`. Check every application runtime against EIP-170. The planner supplies static constructor arguments and no initialization transactions for the application contracts; it does not write the network's final launch manifest or replace its factory.

Uniswap's [custom-accounting documentation](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) describes the hook deltas used here. The immutable 2% applies to this pool's hook charge. Uniswap PoolManager has external protocol-fee governance; zero LP fee does not prevent its controller from enabling an additional protocol fee. Confirm that deployment policy permits the requested total fee, and disclose any later protocol fee. Neither SI nor the hook can control that governance. Other pools and ordinary SI transfers do not incur this hook's fee.

## Operations and verification

The router's `swap(key, params, maxInput, minOutput, recipient, deadline)` collects input from `msg.sender` through ERC20 allowance and sends output directly to `recipient`. Approve an appropriate input amount, choose a deadline and both slippage limits, and use the returned adjusted balance delta for actual input/output. It reads no environment variables. No contract here performs an internal swap except the separate user-facing router.

SI is plain and immutable. The configured IMD must have ordinary, non-rebasing, non-taxed balance semantics; no hook can keep swaps working if IMD prevents the trader's underlying payment or the trader's output transfer. Recipient-specific distribution failures are isolated. An external IMD issuer with seizure or upgrade powers could affect IMD even in the vault; the vault itself supplies no withdrawal authority.

All Solidity dependencies and licenses are ordinary files in `lib/`; revisions are in [DEPENDENCIES.md](DEPENDENCIES.md). A local Solidity 0.8.26 compiler and a Cancun-capable EVM are required. No network, environment configuration, FFI, filesystem cheatcode permission, submodules, or package install is needed to test:

```sh
forge build
forge test
forge fmt --check
```

Tests use a real local Uniswap v4 PoolManager and cover token supply/allowances, permanent holdings, launch settlement, input fees in both directions, exact-input/output and partial fills, payout failures and retries, authorization, slippage, and accounting conservation. The protected environment-driven harness is an external admission check; the delivered tests are self-contained and do not impersonate its environment.

Before release, the network operator must resolve the missing deployment parameters, confirm the chosen on-chain name, confirm that its launch factory can select this custom fee hook, verify deployed bytecode and the final pool key, arrange pending-fee retries, and obtain the separate independent adversarial review requested by the assignment. Local tests and an implementation review are not a security audit. No transactions have been broadcast.
