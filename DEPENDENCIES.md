# Vendored dependencies

Existing Solidity dependencies are ordinary files under `lib/`; the added OpenZeppelin subset is under `src/vendor/openzeppelin/`. Builds and tests require no network once Solidity 0.8.26 is available.

| Dependency | Pinned commit | Included files | License |
| --- | --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/` excluding upstream test scaffolding, license | BUSL-1.1 and MIT, per file |
| [Foundry forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/` and licenses | MIT / Apache-2.0 |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol` and license | AGPL-3.0-only |

Sources were downloaded from the pinned GitHub archives or raw files. No source modifications were made. Solmate's commit matches the dependency pinned by v4-core. The v4-core revision exposes `SwapParams` and `ModifyLiquidityParams` through `PoolOperation.sol`, as required by the supplied compatibility checks.

These copies include PoolManager to run actual local integration tests. Deployments should use the target chain's independently verified existing PoolManager; this project does not deploy a replacement protocol.

## OpenZeppelin token implementation

`src/vendor/openzeppelin/` contains the ERC20 dependency closure from [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3), commit `dbb6104ce834628e473d2173bbc9d47f81a9eec3`: `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, and `draft-IERC6093.sol`, plus the upstream MIT `LICENSE`. Solidity semantics are unchanged; repository `forge fmt` formatting is applied. Imports are relative, so no remapping, package, submodule, or offline download is needed. Existing `lib/`, build configuration, and dependency lockfiles are unchanged. OpenZeppelin is compiled into SI and adds no external deployed contract dependency.
