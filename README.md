# Icarus Concentrated Liquidity Contracts

This repository contains the smart contracts for the Icarus Concentrated Liquidity contracts. It contains
the core concentrated liquidity contracts, adapted from UniswapV3's core contracts. It contains the higher level
periphery contracts, adapted from UniswapV3's periphery contracts. It also contains gauge contracts, adapted from Aerodrome slipstream contracts.  

## Forking History

1. Initial code.

    Repository forked from `aerodrome-finance/slipstream` at commit `02beff19446a74e442980ea5afa1d0124dc57d20`.

2. Updated Pool cotracts to newest version. 

    All GPL-2.0- and MIT-licenced contracts were copied from `aerodrome-finance/slipstream` at commit `5b529b4d418a6d2e394391a153dfbd0c98de937d`.

3. Fix compiler errors and implement changes to gauges based on MIT interfaces.

    Commits `3d442a27c9da4d5957c0e32c3f3a2ad2ed215dec` and `52c623812fa7554d0e0edbaee0c34fd2894233da`.

4. Update Pool contracts to the superchain-slipstream contracts

    All GPL-2.0- and MIT-licenced contracts were copied from `velodrome-finance/superchain-slipstream` at commit `5643f6999f2fdea29aab13f20163575e1cf4c123`.

    > Changes from Slipstream V2 to Superchain Slipstream contracts are in the commit `1f0614ccf45d71e5f3253196e2d47d25868c8d0f`.
    > 
    > They are also listed in the `CHANGELOG-SCSL.md`

## Installation

This repository is a hybrid hardhat and foundry repository.

Install hardhat dependencies with `yarn install`.
Install foundry dependencies with `forge install`.

Run hardhat tests with `yarn test`.
Run forge tests with `forge test`.

## Testing

### Invariants

To run the invariant tests, echidna must be installed. The following instructions require additional installations (e.g. of solc-select). 

```
echidna test/invariants/E2E_mint_burn.sol --config test/invariants/E2E_mint_burn.config.yaml --contract E2E_mint_burn
echidna test/invariants/E2E_swap.sol --config test/invariants/E2E_swap.config.yaml --contract E2E_swap
```

## Licensing

As this repository depends on the UniswapV3 `v3-core` and `v3-periphery` repository, as well as Aerodrome Finance `slipstream` repository, the contracts in the 
`contracts/core`, `contracts/periphery` and `contracts/gauges` folders are licensed under `GPL-2.0-or-later` or alternative 
licenses (as indicated in their SPDX headers).
