---
read_when: Updating GitHub Actions checks, changing Solidity tooling versions, or reproducing CI failures.
---

# CI checks

The Echidna matrix runs all eleven math and oracle harnesses in assertion mode.
Keep Echidna 2.2.0 paired with `slither-analyzer==0.10.4`: newer Slither releases
emit assertion-location objects that this Echidna version cannot decode. The
resulting `expected Array, but encountered Object` error happens before fuzzing,
so it is not an invariant counterexample. Foundry is pinned to v1.7.1.

Reproduce a campaign after installing the workflow's tool versions and solc 0.7.6:

```sh
yarn install --frozen-lockfile
echidna contracts/core/test/TickMathEchidnaTest.sol --contract TickMathEchidnaTest --config echidna.config.yml
```

Repeat for every harness listed in `.github/workflows/fuzz-testing.yml`. Checking
workflow syntax or matching the JSON schema does not prove campaigns pass; the
complete Linux matrix must finish successfully. Local verification may need a
Linux runner when the pinned tools are unavailable on the host architecture.
Do not disable Slither or assertion tests to work around an incompatible pair.

The lint job checks TypeScript test formatting with `yarn format:check`.
Its step label should match that scope.

Foundry swap regression fixtures use explicit JSON field readers. Generic JSON
inference can encode numeric `executionPrice` strings as integers, making the
result incompatible with the expected Solidity struct's string field. Typed
readers preserve string values and signed amounts without changing the expected
swap results. Failed-swap fixtures call their price field `poolPriceBefore`;
successful-swap fixtures use `poolPriceBeforeX96`.

Production-Voter integration tests require core's `claimHook()` and claim-and-lock
APIs. The tests workflow defaults to core commit
`a05e28fbc4e7521f87678fdbe0b90cea3ce89be3`, which includes those APIs.
Repository variable `ICARUS_CORE_REF` overrides this default: remove an obsolete
override or point it at a compatible commit when upgrading. Build the exact core
revision before testing with `ICARUS_CORE_ARTIFACTS=.core-contracts/out` as shown in
[claim-and-lock](claim-and-lock.md). Pinning the test dependency does not migrate
any deployed Voter or gauges.
