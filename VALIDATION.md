# Local validation — Swarm Inu

Toolchain: Foundry **1.7.1** (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`), Solidity **0.8.26** as pinned by the unchanged `foundry.toml`, Cancun EVM, optimizer 200, `bytecode_hash = "none"`.

- `forge build`: passed, with advisory lint warnings.
- `forge test`: **78 passed, 0 failed, 0 skipped across 9 suites**, including fuzz tests and the token/vault and both currency-order fee invariant suites.
- `forge fmt --check`: passed.
- `git diff --check`: passed.
- Runtime sizes from compiled artifacts: SI 1,722 bytes; vault 590; hook 5,847; router 4,050; local planner 20,488. All are below the 24,576-byte EIP-170 limit.

The token's constructor metadata now reads **Swarm Inu / SI**, retaining 18 decimals and the one-time 1,000,000,000 SI mint to its deployer. The existing immutable fee hook and permanent vault were retained. No sample token, owner mint/burn controls, proxy, or upgrade component is part of these production contracts. Existing compatibility helpers remain because the launch tests use them; the production pool must use `SIFeeHook`.

Four added integration tests cover:

- A first exact-input sell into an IMD-only pool, where the real SI token rejects both fee transfers until trader input settles. The swap succeeds, all fees remain claim-backed, and permissionless partial retries update the burn metric only on actual delivery.
- The same insufficient-SI condition for an exact-output sell in the reverse currency order, preserving actual wallet spend and output accounting.
- An injected SI burn-transfer failure: vault payment and later buys/sells still succeed, debt accumulates only for the dead address, recovery pays once, and duplicate retry is rejected.
- Injected IMD recipient balance-query failures: buys and their settlement succeed, unsuccessful retries preserve claims, and recovery delivers the original 80/20 entitlements.

The single-sided sell tests use the actual SI runtime and actual vendored Uniswap v4 PoolManager, with no mocked fee transfer. The other two additions use Foundry call fault injection to isolate payout failure from otherwise valid token settlement. Existing tests cover buy/sell splits, rounding, exact input/output, partial fills, absent administrative selectors, reentrancy, false/malformed/no-return transfers, underpayments, oversized revert data, payout gas exhaustion, bounded retries, slippage rollback, and permanent vault holdings.

Tests need no RPC, network, environment reads/writes, FFI, filesystem cheatcode permission, or broadcast. Fuzz tests run 256 cases, with the two boundary fuzz tests configured for 1,000 cases each. Stateful suites run 256 sequences of 64 handler calls with unexpected reverts treated as failures. No dependencies, build configuration, or protected paths were changed.

The build linter reports advisory signed-cast and unchecked-transfer warnings, among others. Fee casts are bounded by the hook's sign/int128 checks; payout debt is updated before transfer and restored atomically on failure; both automatic payout and manual retry paths bound gas and avoid copying outer return data. Warnings were not suppressed.

No Slither, Mythril, live-chain fork, independent audit, or external network admission check ran. Nothing was deployed, replaced, or re-minted on chain. Before release, the operator must verify the existing SI/vault, IMD semantics, PoolManager, creator wallet, CREATE2 factory, atomic initialization, liquidity custody, and pending-fee retry operations. The historical `launch.json` still describes an incompatible token/vault-only launch; it is not a deployment plan for this hook. README.md records the missing addresses, required zero-LP-fee pool, partial-fill router requirement, and limits of the non-blocking guarantee.
