# Local validation

Validated using Foundry 1.8.3 and the compiler pinned in `foundry.toml`, Solidity 0.8.26, with Cancun EVM settings, optimizer 200, and `bytecode_hash = "none"`.

- `forge build`: passed.
- `forge build --sizes`: passed; production runtimes are 1,337 bytes (SI), 590 bytes (vault), 5,839 bytes (hook), and 4,050 bytes (router), all below EIP-170.
- `forge test`: 39 tests passed across four suites, zero failures. Four fuzz tests use 256 runs each.
- `forge fmt --check`: passed.

The fee integration suite executes the actual vendored PoolManager. Failure cases include recipient reverts, false returns after balance mutation, missing/short return data, gas exhaustion, oversized revert data, reentry, wrong callers/pools, insufficient allowance, slippage/deadline failures, and invalid retry recipients/amounts. It checks full and partial fills, empty liquidity, both currency orderings, first-buy fee deferral, direct donations, preservation of pre-existing router claims, exact settlement, and backing of pending payouts.

The deployment-plan suite deploys the planned CREATE2 initcodes through a local factory, checks all predicted addresses and immutables, verifies supply remains entirely with that factory, and initializes the pool with the production hook. Opening prices are compared with independent integer reference values for IMD decimals 0, 6, 18, and 36 in both currency orders.

Foundry's build linter emits advisory cast, external-call, event-order, timestamp, and zero-address-check warnings. Review covered their relevant preconditions: casts follow sign/range checks or source-type bounds; the router/hook set reentry guards before external calls; token code checks reject zero addresses; the router timestamp comparison enforces a caller-selected deadline; payout calls have bounded gas and return copying. The launch settlement helper intentionally uses the combined liquidity delta, rather than the separately reported fee component.

An independent implementation reviewer examined the hook/router accounting during development. No Slither, Mythril, live-chain fork, deployment, or independent network admission run was performed. The supplied protected harness needs external launch environment data and remains the network verifier's responsibility. These local results do not replace the pre-release adversarial review or the deployment checks listed in README.md.
