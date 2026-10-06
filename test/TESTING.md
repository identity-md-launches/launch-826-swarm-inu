# SI adversarial test additions

The tests use the vendored Foundry and Uniswap v4 sources and need no network, RPC, environment mutation, or extra dependencies.

| Suite | Properties and failure paths |
| --- | --- |
| `invariant/TokenVaultInvariant.t.sol` | Four actors transfer, approve, revoke, spend allowances, donate, and attempt vault exits over time. An independent ledger checks every balance and allowance, the fixed supply, and permanent SI/IMD/dead-address custody. |
| `invariant/SIFeeAccountingInvariant.t.sol` | Three traders swap in both directions, request exact input/output, hit price limits, round-trip, donate SI, change payout-token behavior, retry debts, and submit invalid swaps. Both currency orderings run against the real local PoolManager. |
| `SIAdversarialBoundaries.t.sol` | One-wei and fee/split thresholds, integer limits, callback ordering, pool-key validation, constructor rejection, router recipients, finite/infinite allowances, malformed token returns, transfer-tax settlement mismatch, and settlement reentrancy. |

Each invariant campaign uses 256 sequences of 64 calls with `fail-on-revert = true`, configured in Solidity. Expected rejection paths explicitly check their errors. Only handler action selectors are targeted. Known funded states and deterministic sequence witnesses ensure the campaigns exercise transfers, deferred debts, failed retries, partial fills, and recovery.

The fee oracle uses actual trader wallet spend and the requested 2% rate. It checks each destination's delivered tokens plus pending fees against independently accumulated entitlements. Pending fees must exactly equal the hook's ERC6909 claims, those claims must have token backing in the PoolManager, and the router must retain no swap tokens or refund claims. After each sequence, recipient behavior is restored and every remaining debt must be deliverable. SI sent to the dead address stays in the fixed ERC20 supply and is separately counted as burned, as required by the requested dead-address mechanism.

The external-token mocks model payout failures and settlement quirks. `SettlementIMD` deliberately shares the payout mock's initial storage layout so tests can replace the external token runtime without altering the production SI, vault, hook, router, or PoolManager. The hook itself bounds retry gas; the handlers also supply explicit transaction gas budgets. Payout modes additionally cover true-returning no-op and taxed transfers, whose mutations must roll back while preserving recipient debts.

Run all checks with:

```sh
forge build
forge test
```

No fork test was run. Live deployment addresses, the deployed IMD token, factory admission, and production liquidity still need verification against the target chain; the offline suite does not establish those facts.

`SIFeeHardening.t.sol` covers false-success/underpaid transfers, gas exhaustion at both fee destinations, bounded retries, oversized revert data, low-gas deferral, retry reentrancy, duplicate retries, invalid creator destinations, and absence of administrative selectors. `PrepareLaunch.t.sol` additionally deploys only the planned fee hook/router while preserving an existing token and vault, and initializes through an unrelated caller. The token suites use OpenZeppelin's IERC6093 errors, including InvalidApprover for a zero-from transferFrom that reaches allowance validation.
