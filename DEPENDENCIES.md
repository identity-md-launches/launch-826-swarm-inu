# Vendored dependencies

All required Solidity dependencies are ordinary files under `lib/`; builds and tests require no network once Solidity 0.8.26 is available.

| Dependency | Pinned commit | Included files | License |
| --- | --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/` excluding upstream test scaffolding, license | BUSL-1.1 and MIT, per file |
| [Foundry forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/` and licenses | MIT / Apache-2.0 |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol` and license | AGPL-3.0-only |

Sources were downloaded from the pinned GitHub archives or raw files. No source modifications were made. Solmate's commit matches the dependency pinned by v4-core. The v4-core revision exposes `SwapParams` and `ModifyLiquidityParams` through `PoolOperation.sol`, as required by the supplied compatibility checks.

These copies include PoolManager to run actual local integration tests. Deployments should use the target chain's independently verified existing PoolManager; this project does not deploy a replacement protocol.
