# CHANGELOG-SCSL (Superchain Slipstream)

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