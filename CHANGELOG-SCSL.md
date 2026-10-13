# CHANGELOG-SCSL (Superchain Slipstream)

A list of all the changes made to the audited version of `velodrome/superchain-slipstream` repository.

## Core

### CLFactory (contracts/core/CLFactory.sol)

- Deleted `gaugeFactory` and `nft` addresses.
- Added `factoryRegistry` address.
- Defaulted to msg.sender as owner, swapFeeManager, unstakedFeeManager in `constructor()`.
- Removed deterministic assignment of gauge address in `craetePool()` using `CreateXLibrary`.

### CLPool (contracts/core/CLPool.sol)

- Added `factoryRegistry` address.
- Added `onlyGaugeFactory()` modifier.
- Assigned factoryRegistry instead of `gauge` and `nft` at `initialize()`.
- Added `positionUpdate` argument to `stake()` and conditional check to update the position information.
- Added `setGaugeAndPositionManager()` callable by the `GaugeFactory` to set the `gauge` and `nft` addresses.

## Gauge

### CLGauge (contracts/gauge/CLGauge.sol)

- Added single-position and aggregate account IRS claim-and-lock into owned/new veNFTs.
- Added the shared Voter claim-hook callback with gauge context to positive liquid, locked and withdrawal claims.
- Added real CL/VotingEscrow integration regressions; see [claim-and-lock](docs/claim-and-lock.md).
- Add `WETH9` adn `gaugeFactory` addresses.
- Remove `bridge` address.
- Change `initialize()` to initialize `WETH9`.
- Remove `Q128` constant in favor of `FixedPoint128.Q128`.
- Add `positionUpdate` argument to `pool.stake()` calls.
- Add conditional check in `withdraw()` to not call `pool.stake()` if `liquidityToStake`is 0.
- Change implementation of `stakedValues()`
- Add `supportsPayable()` function.
- Change authorized callers in `notifyRewardAmount()` and `notifyRewardWithoutClaim()`.

### CLGaugeFactory (contracts/gauge/CLGaugeFactory.sol)

- Deleted `xerc20` and `bridge` addresses.
- Added `implementation` address.
- Changed `constructor()`.
- Added `setNonfungiblePositionManager()`.
- Removed deterministic deployment of the gauge in `craeteGauge()` using `CreateXLibrary`.
- Use `Clones.cloneDeterministic()` to deploy gauges.

## Periphery

- Changed mentions of Aerodrome to Icarus in `NFTDescriptor` and `NFTSVG` contracts.

## Libraries

- Renamed `VelodromeTimeLibrary` to `ProtocolTimeLibrary`.

---

# For more curious minds

A list of all the changes made to the Slipstream V2 pool contract (forked from `aerodrome/slipstream` repository) by copying over pool contracts of `velodrome/superchain-slipstream` repository.

## Core

### Fees (contracts/core/fees/)

- Added `factory` address to `CustomSwapFeeModule.sol` and `CustomUnstakedFeeModule.sol`.

### Tick library (contracts/core/libraries/Tick.sol)

- Added `rewardGrowthGlobalX128` parameter to `update()` function.

### CLFactory (contracts/core/CLFactory.sol)

- Made `getPool` a function to return internal `_getPool`.
- Made `enableTickSpacing` a function that calls internal logic.
- Added `createPool()` without `sqrtPriceX96` argument, that creates pool with `encodePriceSqrt(1, 1)` price.
- Increased `gas` in `excessivelySafeStaticCall` on swapFeeModule.
- Added `isPair()` function

### Pool (contracts/core/CLPool.sol)

- Added `tokens()` view function.
- Added `rewardGrowthGlobalX128` argument in calling `update()` on ticks.

## Periphery

Code size optimizations were applied when needed: removing string errors from various `require()` statments.

### NonfungiblePositionManager (contracts/periphery/NonfungiblePositionManager.sol)

- Added `_owner` argument to the constructor.
- Added `userPositions()` to fetch all user positions.
    - Added internal `_userPositions` as `IterableEnumerableSet`.
    - Added `_beforeTokenTransfer()` to update `_userPositions`.
    - Added update to `_userPositions` in the `burn()` function.
    - Removed checks for staked liquidity on `increaseLiquidity()` and `decreaseLiquidity()` as `CLGauge` no longer can call these functions on behalf of staked user. 

### SugarHelper (contracts/periphery/SugarHelper.sol)

- Change one condition check from AND to OR in `estimateAmount0()` and `estimateAmount1()` functions.
