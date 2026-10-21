---
read_when: Deploying Cyclotron private pools, configuring permissions or fees, integrating the Cyclotron proxy, or registering private gauges with the Voter.
---

# Cyclotron private CL pools

`CLPrivateFactory`, `CLPrivatePool` and `PrivateNonFungiblePositionManager` are isolated
forks of `CLFactory`, `CLPool` and `NonfungiblePositionManager`. Public contracts and
gauge/reward implementations are unchanged. Arbera and Cyclotron use
one private factory; Cyclotron is the Robinhood rebrand.

## Permissions

The factory starts with an empty `isWhitelisted` mapping. The factory `owner` is the
team administrator, initially the deployer, and calls `setWhitelist(account, allowed)`,
which emits an event. The private NFT manager reads this same whitelist for its callers.
Its own `publicLiquidity` flag controls new NFT minting and starts false; only its `owner` may call
`setPublicLiquidity(allowed)`, which emits an event. The factory and pool have no public
liquidity toggle.
Ownership does not implicitly authorize pool creation or pool operations. Zero-address
whitelist entries are rejected. `setOwner` transfers administration using the existing
factory mechanism; fee-manager roles remain separate.

| Operation | Permission |
| --- | --- |
| Both factory `createPool` overloads | Immediate caller whitelisted |
| Pool `swap` and `flash` | Immediate caller whitelisted |
| Pool `mint`, including liquidity increases | Immediate caller whitelisted |
| Private NFT manager `mint` | Caller whitelisted OR manager public liquidity enabled |
| Private NFT manager pool creation during `mint` | Caller whitelisted, including when public liquidity enabled |
| Private NFT manager `increaseLiquidity` | Anyone may add to an unstaked NFT; staked NFTs reject increases |
| Burn, collect, gauge deposit/withdraw/claim | Existing ownership and gauge/NFT-manager rules |
| Read methods and oracle cardinality growth | Existing behavior |

Revocation affects guarded calls across every pool and new mints through the private NFT
manager. Closing the manager's public liquidity mode blocks new NFT minting by unlisted
callers; existing positions can still be increased, decreased or exited under their existing
rules. Recipients are not checked. Public liquidity opens new NFT minting through
the private manager only; direct pool minting, swaps, flash loans and pool creation remain
permissioned. Public callers must pass `sqrtPriceX96 == 0` to mint into an existing
pool; a nonzero value enters the pool-creation path and requires whitelist authorization.
The manager itself must remain factory-whitelisted in both modes.

### Cyclotron proxy and NFT manager

The pool checks `msg.sender`, never `tx.origin`, callback data, or the recipient. For
`user -> Cyclotron proxy -> PrivateNonFungiblePositionManager -> pool`, the pool sees the
**NFT manager**. Whitelist the private manager in the factory to authorize its pool calls;
also whitelist the Cyclotron proxy to authorize its calls to the manager in permissioned
mode. Whitelisting only the proxy or user is insufficient for the pool check.

The private manager guards only `mint`; its whitelist comes from the
factory and its public-liquidity setting is local to the manager. The owner has no implicit
minting permission. `multicall` preserves the original caller, so batching cannot bypass
this guard. Mint callbacks keep the existing deterministic pool authentication and do not
apply the wallet whitelist to the pool callback caller.

`increaseLiquidity` retains the public manager's behavior: anyone can fund an unstaked NFT,
including an NFT owned by someone else. This is a donation to that position, not ownership
or withdrawal authority. Increases are rejected while the gauge owns the NFT.
Whitelist revocation does not add restrictions to `increaseLiquidity`, `decreaseLiquidity`, `collect`, `burn`,
NFT approvals/transfers, or gauge operations: their existing authorization rules remain.
For proxy-controlled withdrawals and rewards, the proxy must mint NFTs to itself and deposit
them into the gauge as the staker. The gauge then owns each NFT; only its recorded staker
can withdraw it or directly claim its IRS rewards. Withdrawal returns the NFT and rewards to
the proxy, which must account for its users and pass on their emissions. The proxy must
atomically unstake, increase/decrease and restake when managing a position, or unstake,
decrease, collect and burn when exiting. It must retain custody throughout and avoid external
NFT approvals. Returning NFTs or granting external approvals allows those authorized accounts
to manage or exit the positions directly. These are required proxy behaviors; no production
Cyclotron proxy implementation is included here.

Whitelisting a standard public NFT manager would still allow users to call mint/increase
directly, bypassing Cyclotron's proxy. Use the private manager for permissioned NFT creation.
Removing the proxy from the whitelist blocks its new mints while preserving management of
existing NFTs, as long as the private manager itself remains factory-whitelisted for pool mints.
Likewise, whitelisting a public swap router allows every router user to swap; use trusted
executors that enforce their own upstream caller permissions. This change introduces no
production Cyclotron proxy or permissioned swap router.

New CLGauge deployments support `deposit(tokenId, recipient)` as described in
[mint-and-stake integration](liquidity-stake-helper.md). An adapter choosing that overload
gives the recipient direct claim and withdrawal rights; use the original self-deposit API
when proxy-controlled custody is required. Existing gauge deployments do not gain the overload.

Third-party gauge deposits additionally require the immediate caller to be whitelisted
in the gauge's `CLGaugeFactory`. This separate whitelist is administered by that factory's
retained deployment owner or the current `VotingEscrow(Voter.ve()).team()`; trusted helpers must enforce
recipient authorization. Private pool-factory whitelisting does not grant this permission.
Self-deposits, claims and withdrawals require no gauge-factory whitelist entry.
Gauge actions require neither the gauge nor the staker to be private-factory-whitelisted. Direct ordinary
mint/swap/flash flows require callback-capable contracts.

## Fees

The private factory deploys and installs its own `PrivateSwapFeeModule` in its constructor.
The module returns zero for every pool unless the fee manager sets a per-pool override,
regardless of tick spacing. Swap and flash fees use the same module.

Tick-spacing configuration is identical to `CLFactory`: the standard nonzero spacing fees
are retained, zero means an unsupported spacing, and `enableTickSpacing` requires a
positive fee. There is no separate enabled mapping or spacing-fee update API. Newly enabled
spacings also have zero effective fees through the private module.

The current `swapFeeManager` calls `PrivateSwapFeeModule.setCustomFee(pool, fee)` for a
registered pool. Fees use pips (1,000,000 = 100%); the module retains `CustomSwapFeeModule`'s
30,000 (3%) maximum. Setting zero clears the override and restores zero fees. The existing
`ZERO_FEE_INDICATOR` value 420 is retained for compatibility and also returns zero; it is
not a charge of 420 pips. Overrides affect only the specified pool. Module events and fee
manager rotation work as in `CustomSwapFeeModule`.

The team can still replace the module using the existing factory setter. A reverted or
out-of-bounds module response falls back to the factory's nonzero spacing fee, just like
`CLFactory`. Replacing it with `CustomSwapFeeModule` also restores spacing-fee defaults for
pools without overrides. Zero-default behavior is provided by the installed private module,
not a permanent factory invariant. Token transfer taxes are separate.

Unstaked-fee configuration is unchanged: the initial 10% surcharge applies to applicable
fees, not swap principal. With zero swap fees, there are no swap fees to split. If fees
are enabled later, existing LP/gauge fee accounting applies.

## Deployment and Voter registration

1. Deploy `CLPrivatePool` as the clone implementation.
2. Deploy a **new instance** of existing `CLGaugeFactory`, using the existing Voter and
   compatible `CLGauge` implementation. No `CLPrivateGauge` is needed.
3. Deploy `CLPrivateFactory(voter, poolImplementation, gaugeFactory, gaugeImplementation)`.
   Its constructor installs the zero-default fee module; read `swapFeeModule()` for its address.
4. Deploy `PrivateNonFungiblePositionManager(owner, factory, WETH9, tokenDescriptor, name,
   symbol)` against the private factory. Bind this manager once in both the pool factory and
   its dedicated gauge factory. Call `CLPrivateFactory.setWhitelist(manager, true)` and
   whitelist the Cyclotron proxy. Leave the manager public-liquidity mode disabled for
   proxy-only NFT creation. Deploy other compatible periphery as required.
5. Register the factory path with FactoryRegistry and the voting-rewards factory. The
   configured gauge factory/implementation must match the pool factory's predicted gauge path.
6. Team explicitly whitelists approved creator/executor contracts. Create pools, then
   create gauges through Voter using its normal token and role requirements.

Do not reuse the public gauge-factory **instance**. Its clone salt contains only pair and
spacing, so matching public/private pools collide. Its NFT-manager binding is also one-time.
Reuse the implementation/code instead. Pool address derivation already reads the factory's
implementation. Existing deployed periphery remains bound to its original factory.

IRS funding, voting, gauge liveness and claim-and-lock remain unchanged. These changes
do not deploy contracts or register a factory onchain.

## Verification and maintenance

```sh
forge test --match-path 'test/unit/concrete/CLPrivate*/*.t.sol'
forge test --match-path '*PrivateNonFungiblePositionManager*'
forge test
```

The private manager shares pool-address derivation and whitelist checks through private
helpers to stay deployable without changing the public manager or compiler settings.
At Solidity 0.7.6 with optimizer runs 200, its runtime is 24,537 bytes (39 bytes below
EIP-170). The manager suite asserts the deployment size limit; preserve this check when
editing the fork.

Production-Voter tests use the sibling core artifacts described in [claim-and-lock](claim-and-lock.md).
Coverage includes fee defaults/updates, creation overloads, role changes, revocation,
repayment/reentrancy, manager liquidity-mode isolation, multicall caller boundaries, public/private AMM
differential fuzzing, tick crossings, and gauge lifecycle with mock and production Voters.

Keep future AMM fixes synchronized between the isolated forks. The intended pool diff is
its name, private-factory interface and mint/swap/flash permission checks. Keep NFT-manager
fixes synchronized with its isolated private fork as well. Unrestricted
callback helpers in tests are test fixtures, never production deployment examples.
