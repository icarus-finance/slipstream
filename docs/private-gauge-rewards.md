---
read_when: Deploying CLPrivateGauge, funding initial rewards, switching private gauge rewards to IRS, or integrating campaign claims and refunds.
---

# Private gauge initial rewards and IRS transition

`CLPrivateGauge` is an optional gauge implementation for new private pool deployments.
It uses the existing pool reward counter for one token at a time:

```text
Awaiting initial rewards -> initial rewards -> stopped/checkpointing -> IRS
```

The public `CLGauge`, pools, tick library and NFT manager are unchanged. Existing immutable
gauges cannot gain this behavior. A campaign cannot restart after the IRS transition begins.
Keep future IRS claim, custody, and fee fixes synchronized between the two gauge implementations.

## Deployment and late configuration

Deploy a dedicated `CLGaugeFactory` with the `CLPrivateGauge` implementation. Supply the
same implementation and gauge-factory addresses to `CLPrivateFactory`, so its predicted
gauge address matches the clone created through Voter. The initializer remains compatible
with `CLGaugeFactory`; the new gauge needs no initial reward token address at deployment.

The current `VotingEscrow(Voter.ve()).team()` configures the initial reward token and one fixed
funding wallet once with `configureInitialRewards(token, funder)`, before the transition begins.
The initial reward token must be a contract and distinct from IRS. CYCLO is one possible initial
reward token. Only standard ERC20 transfers are supported; rebasing and transfer-tax tokens
are unsupported.
Deposits before configuration or funding receive no retroactive initial rewards.

`rewardToken()` always identifies IRS. Existing IRS views and claim APIs remain IRS-specific;
use the separate initial-reward views and claim API during the campaign. Initial rewards are liquid
only and never enter VotingEscrow or the shared IRS claim hook.

`earnedInitialRewards(account, tokenId)` reports uncheckpointed earnings for a currently staked position;
it excludes `initialRewardCredits(account)`. `claimInitialRewards(tokenIds)` checkpoints caller-owned
positions and attempts payment of all caller credits. An empty array retries existing credits, including
after withdrawal or IRS activation.

## Funding and stopping rewards

The configured wallet approves the gauge, then calls `notifyInitialRewards(amount)` to
prefund rewards. Repeated calls are allowed, including hourly or daily top-ups. The gauge
checks the actual received balance delta and checkpoints prior earnings before changing
the schedule. Funding runs until the next weekly boundary, not seven days after each call.
Remaining scheduled rewards, idle-period rollover, dust and the top-up form the new budget.
The pool receives only `rate * remainingDuration`; division dust stays separate, so it
cannot extend initial emissions past that schedule.

Top-ups do not change previously earned rewards. They add funding and recalculate the
remaining rate; there is no arbitrary rate setter or early withdrawal of committed funds.
After a schedule expires, new funding may establish a different rate for the next schedule.
Funding ends once the team calls `beginIrsTransition()`. This checkpoints initial reward growth
through that transaction's timestamp and sets the pool rate/reserve to zero. The team can stop
immediately without waiting for the campaign's weekly boundary, token transfers, or an external
mint-pause call.

Users retain all initial rewards earned before the stop. The unused amount becomes refundable only
after every pending position has been checkpointed.

## Transition runbook

1. Record the private NFT manager's factory-whitelist value. Factory owner temporarily
   calls `CLPrivateFactory.setWhitelist(privateNftManager, false)`.
2. Team calls `beginIrsTransition()`. Gauge deposits and initial reward funding are blocked.
3. Process pending positions with bounded `checkpointTransition(tokenIds)` calls. Checkpointing
   is permissionless; payments always go to each position's recorded staker.
4. Once no positions remain pending, return unused initial rewards to the configured funder with
   `recoverUnusedInitialRewards()`.
5. Team calls `finishIrsTransition()` to activate IRS and reopen gauge deposits.
6. Factory owner restores the NFT manager's original whitelist value.

Recovering surplus is not a prerequisite for finalization. If the funder's refund transfer
fails, users' backed credits and the IRS transition remain available; retry the refund later.

Revoking the manager blocks its mints **and liquidity increases across that private factory**.
Setting `publicLiquidity(false)` alone does not block whitelisted minters. Other independently
whitelisted mint executors are not paused by the manager's revocation. Decreases, collection,
gauge exits, and ordinary authorized swaps remain available. Keep the pause as short as practical.

The pending set shrinks as checkpoint calls or withdrawals settle positions. Read pending IDs
again between batches; swap-and-pop removal changes offsets. Reprocessing completed IDs is
harmless. Zero-reward positions also need a checkpoint. No unbounded position-copy operation
is required to begin the transition.

Use `pendingPositions()` for the remaining count and `pendingTokenIds(offset, limit)` for bounded
ID reads. During the campaign these views enumerate all active positions; during transition
they enumerate only pending positions.

Each checkpoint moves newly earned initial rewards into account credits and advances the
position's growth baseline. During transition that becomes its baseline for IRS. The gauge does
not keep a separate cached initial reward amount per NFT. Explicit claims and transition batches
attempt a direct payout. A successful transfer clears the account's credits, reduces aggregate
credits and records the amount paid. A failed transfer leaves credit accounting unchanged and
emits a failure event. Failed transfers do not undo checkpoint progress or block finalization.
Before IRS activation, withdrawals checkpoint into credits only; they
do not attempt a transfer. The user calls `claimInitialRewards([])` to receive those credits.
Credits survive withdrawal, NFT transfer, restaking and IRS activation.
Payout attempts have a separate 150,000-gas limit; a token needing more gas remains unpaid
with credits intact. Supply enough transaction gas for checkpointing and its attempted payouts.

The cumulative pool counter is not reset. During the zero-rate pause, swaps can still cross
ticks without changing a position's accumulated inside growth.

For a small enough pending set, team can instead call `transitionToIRS(tokenIds)`. This named
atomic entrypoint begins the transition, checkpoints the supplied positions with best-effort
payouts, and finalizes IRS in one transaction. The array must cover all positions still pending;
incomplete coverage or another failing step reverts the entire transaction. It does not bundle
the funder's refund or factory whitelist operations. Refund separately afterward.

The gauge has no generic `multicall(bytes[])` entrypoint. An external aggregator using ordinary
`CALL` becomes the gauge's `msg.sender`, so it cannot preserve the team's, funder's or staker's
authority. An authorized Safe can use delegatecall MultiSend to batch its own calls: targets then
see the Safe as caller. Factory owner and gauge team authorizations must still match that wallet.
Batches share transaction gas limits; use the separate checkpoint calls when an atomic transition
would be too large.

## Refunds and outstanding claims

After all pending positions have been settled, the refundable amount is:

```text
total funded - successful payouts - outstanding user credits - prior refunds
```

`unusedInitialRewards()` exposes this amount. `recoverUnusedInitialRewards()` is permissionless
and always sends it to the configured funder. Outstanding user credits remain backed in the gauge,
even when a transfer failed. Queued IRS, pool fee balances and unrelated token donations are not
campaign surplus. This is not an administrative sweep of earned rewards.

For example, if 7,000 units of the initial token are scheduled evenly over seven days and stopped
after exactly three, users retain approximately 3,000 units and approximately 4,000 are refundable.
Idle periods without active staked liquidity can increase the unused amount; integer rounding
can leave a remainder.
The seven-day example applies only when the actual schedule spans seven days.

## IRS funding and activation

Voter may fund the gauge before or during the initial-reward campaign or transition. Both the normal
Voter notification and team IRS funding path pull IRS into a queue; neither overwrites the initial
reward schedule. Before activation, IRS `left()` returns zero so Voter never compares IRS funding with
an initial-token-denominated balance.

IRS accrual can begin at `finishIrsTransition()`, after all positions have their IRS baselines.
Finalization updates the pool timestamp while the rate is still zero before starting queued IRS
through the next weekly boundary. This prevents retroactive IRS accrual over the pause. If no
IRS is queued, the gauge enters IRS mode at zero rate. If the queue is smaller than the seconds
remaining to the weekly boundary, it cannot establish a nonzero integer rate: finalization still
enters IRS mode at zero rate and retains the queue. The next successful normal IRS notification
combines that queue with its new funding to start emissions. All users need not have successfully
received their initial rewards for IRS to start.

Normal IRS claim, lock and shared-hook behavior applies afterward; see
[IRS claim-and-lock](claim-and-lock.md). A custody adapter remains the gauge's staker and must
separately attribute and forward both tokens to its underlying users.

## Verification

Build matching core artifacts first as described in [IRS claim-and-lock](claim-and-lock.md), then:

```sh
forge test --match-path 'test/unit/concrete/CLPrivateGauge/*.t.sol'
forge test --match-path 'test/unit/{concrete,fuzz}/CLPrivateGaugeParity/*.t.sol'
forge test --match-path 'test/unit/concrete/CLPrivateFactory/*.t.sol'
forge test --match-path 'test/unit/concrete/CLPrivatePool/*.t.sol'
forge test --match-path 'test/unit/concrete/PrivateNonFungiblePositionManager/*.t.sol'
forge test --match-path 'test/unit/{concrete,fuzz}/CLGauge/*.t.sol'
```

Focused integrated runbook and randomized lifecycle checks can also be run separately:

```sh
forge test --match-path 'test/unit/concrete/CLPrivateGauge/privateFamilyE2E.t.sol'
forge test --match-path 'test/unit/concrete/CLPrivateGauge/lifecycleFuzz.t.sol' --fuzz-runs 5000
```

The private-gauge suite includes production-Voter and escrow integration using those artifacts.
The parity suites copy all 106 public-gauge test functions and their assertions, using a shared
fixture that deploys the actual private factory, pool, manager and gauge and activates IRS before
testing the public gauge's behavior. Keep these copies synchronized with future public-gauge tests.
Integrated scenarios cover the operator pause/settlement/refund/resume runbook, executor permission
revocation, tick crossings across both reward phases, and full liquidity exit while minting is paused.

`lifecycleFuzz.t.sol` runs seeded action sequences over three positions with randomized initial
liquidity. It combines mandatory successful/failed claims, funding, withdrawal/restake, refund and
IRS payout steps with 8–32 randomized actions in each reward phase. Actions vary top-ups, time
advances, claims, deposits/withdrawals, authorized tick crossings, payout failures, IRS funding and
token donations. Transition checkpoints run in batches across randomized pauses, including epoch
boundaries. Refunds occur before or after IRS activation while a user's blocked payout remains
backed; the sequence later retries the claim and exits the positions.

The reference ledger derives initial and IRS schedules from funding inputs, elapsed time, known
ranges and NFT liquidity. It does not read pool/gauge reward counters or `unusedInitialRewards()`
to calculate expected entitlements or refunds. The range/time oracle implements Q128 flooring;
real authorized crossings checkpoint growth at every modeled time boundary so its integer
comparisons use the same rounding boundaries. After every modeled action, assertions compare
recipient balances, funder cash, gauge token balances, credits, custody and active liquidity against
that independent ledger. They check conservation and backing for earned liabilities and future
scheduled rewards, preserving donations and unpaid credits through refunds and IRS activation.
This is bounded seeded-sequence fuzzing over fixed ranges and two crossing prices, rather than an
unrestricted stateful invariant campaign.

On Apple Silicon, native solc 0.7.6 may fail with `Bad CPU type in executable`; use a compatible
0.7.6 compiler runtime rather than editing the tracked compiler or metadata settings. Report
the actual compiler target separately from the test EVM: legacy compiler wrappers may require
Istanbul compilation while core 0.8.30 artifacts require a Shanghai-capable test EVM.

Cover late configuration, weekly top-ups, immediate stops, idle rollover/dust, partial batches,
withdrawals and swaps between batches, failed/reentrant initial-token payouts, protected credits and
refunds, queued IRS, same-block transition calls, and atomic transition success/rollback. Check runtime
size and representative batch and atomic-transition gas with unchanged repository compiler and
metadata settings. Choose batch sizes from measured gas for the deployed chain and token;
no position limit is implied by the examples.
No deployment or onchain configuration is performed by these source changes.
