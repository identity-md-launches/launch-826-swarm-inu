# Swarminu.xyz (SI) — Swarm Inu

SI is the INU for the IMD swarm. The source now inherits the plain OpenZeppelin ERC20; swap fees belong to a separate Uniswap v4 hook. This follow-up changes source only: it does not deploy, replace, or re-mint the existing project token. An immutable deployed token cannot be converted to OpenZeppelin by a source change.

- Website: https://www.swarminu.xyz/
- Twitter: https://x.com/swarminu
- On-chain name: **Swarminu.xyz**; symbol: **SI**; decimals: **18**.
- Supply: **1,000,000,000 SI**, or **1000000000000000000000000000** minor units, minted once to the constructor's `msg.sender`.

The brief contains both “Swarminu.xyz” and “Swarm Inu” as token names. This implementation uses the first, structured token name on-chain and uses Swarm Inu as the project name. There is no mechanism to rename the deployed token.

## Contracts

| Source | Purpose |
| --- | --- |
| `src/SwarmInu.sol` | OpenZeppelin Contracts 5.0.2 ERC20, with constructor-only minting. No owner, later minting, transfer tax, freeze, blacklist, burn authority, proxy, or upgrade. |
| `src/SICommunityVault.sol` | Permanent ERC20 sink. No outgoing transfer, approval, withdrawal, execution, redemption, or claim function. |
| `src/SIFeeHook.sol` | Immutable 2% input fee, fixed destinations, and failure-tolerant payouts. |
| `src/SISwapRouter.sol` | Direct caller-to-PoolManager settlement, slippage limits, and input-fee refunds for partial fills. |
| `script/PrepareLaunch.s.sol` | Explicit-argument CREATE2 planning; `prepareFees` reuses an existing token and vault. No broadcasting or key access. |

`LaunchLiquidity`, `HookFlags`, and `PoolInitializationGuard` are compatibility helpers for the supplied launch checks. **The production pool must use `SIFeeHook` as `PoolKey.hooks`.** `PoolInitializationGuard` alone does not charge fees. The supplied protected test creates its own guard, so it establishes ERC20 launch compatibility, not fee-hook deployment correctness.

## Fees and permanent holdings

The supported pool has SI and the configured IMD ERC20, `fee = 0` (zero LP fee), and `tickSpacing = 60`. Its fee hook address must have low 14 bits `0x20cc`: before-initialize, before-swap, after-swap, and both swap delta permissions. Pool initialization is permissionless through PoolManager; the hook validates the pool key, with no privileged initializer. Deploy and initialize atomically to prevent a third party selecting the initial price. There is no setter for the 2% fee or its destinations, no owner, no pause, and no upgrade mechanism. This implements the fixed-fee option; it does not use a dynamic LP-fee controller.

| Trader input | Hook fee | Distribution |
| --- | --- | --- |
| IMD (buy SI) | 2% in IMD | 80% vault, 20% immutable creator receiver |
| SI (sell SI) | 2% in SI | 50% vault, 50% `0x000000000000000000000000000000000000dEaD` |

For a fully filled exact-input swap, the fee is `floor(grossInput / 50)` and the remaining input reaches the AMM. For exact-output swaps and partial exact-input fills, it is `floor(actualAmmInput / 49)`, so the fee is 2% of the gross amount paid, rounded down to token minor units. Tiny swaps can round to zero. The creator share is `floor(fee / 5)` on buys; the burn share is `floor(fee / 2)` on sells; the vault receives each split's rounding remainder. No output-token fees are charged. Exact-output routing can also fill partially at a price limit; set `minOutput` to the desired output if a complete fill is required.

Use **SISwapRouter for partial exact-input fills**. v4 only lets an after-swap callback change the unspecified currency. The hook therefore reserves the input fee before the swap and issues a claim for any unused fee to this router; the router burns that claim to reduce the input debt before collecting payment. Other routers work for full exact-input fills and exact-output swaps. A partial exact-input fill through another router reverts atomically with `PartialFillRequiresRouter`, instead of charging a fee on unused input. Routers must include the hook fee in their input limits. Fee logic does not inspect or trust caller-supplied hook data.

The hook first backs each fee with PoolManager ERC6909 claims. It attempts each distribution separately within a fixed gas allowance. A reverting, false-returning, malformed-returning, or gas-consuming recipient-specific token transfer leaves the unpaid amount in `pending(currency, recipient)` and keeps its backing claim. Transfers that mutate balances then return false are rolled back at the external self-call boundary. Each successful transfer must increase the recipient balance by exactly the owed amount; a true-returning no-op or underpayment also rolls back and remains pending. The entire automatic attempt, including balance queries, is capped at 120,000 gas, and return data is not copied by the outer call. There is no alternate destination or administrator who can collect these claims.

Anyone can call `flush(currency, recipient, amount)` to retry an existing debt, including a partial amount. The entire PoolManager unlock used for a retry is capped at 200,000 gas and the outer call copies no return data. A failed retry returns false and leaves the debt intact. A retry with too little gas available for the cap plus cleanup is skipped and returns false; allow at least 350,000 transaction gas for a normal retry. These limits cannot guarantee completion of a transaction submitted with arbitrarily insufficient gas. A successful retry burns the backing claim and transfers only to the recorded recipient. On a first buy into a single-sided pool, the manager may not yet hold IMD when the hook runs; fees then remain pending until the trader's input settles and somebody calls `flush`. Low available gas can also defer automatic payout. A keeper or UI should monitor `PayoutDeferred` and retry; retries earn no reward. A permanently blocked recipient leaves its fee claim pending permanently and does not disable swaps.

Vault views read actual balances:

- `totalIMDHeld()` includes all IMD donations and successfully delivered fees.
- `totalSILocked()` includes all SI donations and successfully delivered fees.
- `totalSIBurned()` is the SI balance of the dead address, including direct transfers by anyone.

Pending hook claims are not yet vault balances or completed burns. Sending SI to the dead address does **not** reduce ERC20 `totalSupply`. Anyone donates simply by transferring tokens to the vault; there are no shares or holder entitlements. Tokens accidentally sent to the hook/router, and unrelated tokens sent to the vault, have no rescue path.

## Deployment parameters and launch economics

The project context identifies launch 826 on Ethereum mainnet (chain ID 1) as parked. Existing token and vault addresses, a verified PoolManager address, verified IMD address/decimals, and the creator receiver are not supplied as deployment configuration. `launch.json` is historical provenance and explicitly describes an incomplete token/vault-only integration with a 3000 LP fee; that pool configuration does not deploy this fee system. It is not a transaction plan. The fee hook continues to require zero LP fee; it must not silently accept an extra 0.3% to satisfy an external admission restriction. The network operator must support the actual hook pool before release. Addresses in historical artifacts and the upstream tables are unverified here. The remainder wallet below is not assumed to be the creator receiver.

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

For this follow-up, call the view function `PrepareLaunch.prepareFees(FeeConfig)` on the target-chain state or a reviewed fork. All inputs are function arguments; it reads no environment variables:

| Parameter | Required value |
| --- | --- |
| `factory` | Actual CREATE2 deployer; salts are bound to this address and the compiled initcode |
| `manager` | Verified existing Uniswap v4 PoolManager on the target chain |
| `si`, `imd` | Existing project SI and verified paired ERC20; distinct deployed contracts |
| `vault` | Existing immutable SICommunityVault with the same SI/IMD pair |
| `creator` | Permanent creator recipient; nonzero, distinct from tokens, vault, hook, router, manager and dead address |
| `launchNumber` | Deterministic salt domain, e.g. 826 after checking address availability |

The result contains only router and hook deployment initcode, their salts/addresses, the existing token/vault addresses, and the pool key. Deploy the router, then the mined hook, and initialize the pool in the same transaction at an independently reviewed starting price. Initialization can be called by any address; the factory has no reserved authority. The function neither calculates a migration price nor moves liquidity. Funding a new pool and custody of any LP position require the operator's separate arrangements. Do not deploy another SI token or mint any new supply. `prepare(...)` remains a historical fresh-launch planner for reproducing the original tests, not the entry point for this follow-up.

The hook constructor is `SIFeeHook(manager, si, imd, vault, creatorReceiver, partialFillRouter)`. It verifies deployed token/manager/router code, matching vault/router configuration, distinct creator destinations, and address permission bits. The router must be this project's `SISwapRouter` configured for the same manager. Code-presence checks do not attest production implementations: verify actual runtime code, constructor arguments, chain, pair decimals, CREATE2 salts, and EIP-170 sizes independently. This source update changes creation-code hashes, so old predicted addresses/salts cannot be reused without recomputation. The planner does not write the network's final launch manifest.

The vendored `v4-core/src/libraries/Hooks.sol` defines the custom accounting used here. The immutable 2% applies to this pool's hook charge. Uniswap PoolManager has external protocol-fee governance; zero LP fee does not prevent its controller from enabling an additional protocol fee. Confirm that deployment policy permits the requested total fee, and disclose any later protocol fee. Neither SI nor the hook can control that governance. Other pools and ordinary SI transfers do not incur this hook's fee.

## Operations and verification

The router's `swap(key, params, maxInput, minOutput, recipient, deadline)` collects input from `msg.sender` through ERC20 allowance and sends output directly to `recipient`. Approve an appropriate input amount, choose a deadline and both slippage limits, and use the returned adjusted balance delta for actual input/output. It reads no environment variables. No contract here performs an internal swap except the separate user-facing router.

SI is plain and immutable. The configured IMD must have ordinary, non-rebasing, non-taxed balance semantics; no hook can keep swaps working if IMD prevents the trader's underlying payment or the trader's output transfer. Recipient-specific distribution failures are isolated. An external IMD issuer with seizure or upgrade powers could affect IMD even in the vault; the vault itself supplies no withdrawal authority.

All Solidity dependencies and licenses are ordinary files in `lib/` and `src/vendor/openzeppelin/`; revisions are in [DEPENDENCIES.md](DEPENDENCIES.md). A local Solidity 0.8.26 compiler and a Cancun-capable EVM are required. No network, environment configuration, FFI, filesystem cheatcode permission, submodules, or package install is needed to test:

```sh
forge build
forge test
forge fmt --check
```

Tests use a real local Uniswap v4 PoolManager and cover token supply/allowances, permanent holdings, launch settlement, input fees in both directions, exact-input/output and partial fills, payout failures and retries, authorization, slippage, and accounting conservation. The protected environment-driven harness is an external admission check; the delivered tests are self-contained and do not impersonate its environment.

Before release, the network operator must resolve the missing deployment parameters, confirm the existing token and vault addresses, confirm that its launch factory can select this custom fee hook with zero LP fee, verify deployed bytecode and the final pool key, arrange pending-fee retries, and obtain the separate independent adversarial review requested by the assignment. Local tests and an implementation review are not a security audit. No transactions have been broadcast.

## Call permissions and review scope

| Entry point | Caller and authority |
| --- | --- |
| SI `transfer`, `approve`, `transferFrom` | Standard OpenZeppelin balances/allowances; no fee exemption or privileged account |
| Vault views | Anyone; no state-changing methods, withdrawals, approvals, or admin |
| Hook `beforeInitialize`, `beforeSwap`, `afterSwap` | Only the immutable PoolManager, for the exact supported pool key |
| Hook `deliver` | Only the hook itself, used as a bounded rollback boundary |
| Hook `unlockCallback` | Only PoolManager during an active fee retry |
| Hook `flush` | Anyone can pay gas for an existing debt; cannot choose a different beneficiary or exceed that debt |
| Router `swap` | Anyone spends only their own approved input, with deadline and input/output bounds |
| Router `unlockCallback` | Only PoolManager during an active swap |
| Planner | Anyone; computes data without transactions or authority |

The changes address source conformance to OpenZeppelin, privileged initialization, false-success payouts, unsafe creator destinations, and unbounded retry gas. Tests exercise the real vendored PoolManager, including failure recovery and stateful accounting in both currency orders. Non-blocking means distribution failure does not stop an otherwise valid supported swap: it does not waive invalid pool/callback checks, router requirements for partial input fills, token settlement failure, caller slippage limits, or EVM gas requirements. A token that lies in balance queries, rebases, taxes transfers, or changes through external governance is not a supported production IMD.

See [VALIDATION.md](VALIDATION.md) for the checks actually run. Local verification is not an independent security audit. Release still requires independent adversarial review and resolution of the documented deployment inputs and factory integration.
