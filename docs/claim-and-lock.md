---
read_when: Integrating CL emissions claims, configuring shared claim rewards, or deploying CLGauge with the updated Icarus Voter.
---

# CL IRS claim-and-lock

CLGauge uses the same shared claim hook as the V2 gauges in the sibling `contracts` repository.
Team sets `Voter.setClaimHook(hook)` once for every compatible gauge, including future gauges.
Zero disables the hook globally. No per-gauge setting or bonus policy is introduced here.
The production Voter implementation remains in `../contracts`; Slipstream supplies its interface
and an updated test mock, not another production Voter.

## Claims

- Existing `getReward(positionId)` remains callable by the position's staker.
- Existing `getReward(account)` remains Voter-only, claiming each staked position liquid.
- `getRewardAndLock(positionId, veTokenId, lockDuration)` claims one staked LP position into a lock.
- `getRewardAndLock(account, veTokenId, lockDuration)` claims all account positions into one lock.
  Caller must be account or Voter. Checkpoints and consumes each position before settlement,
  then funds escrow once and calls the hook once for the aggregate positive reward.
- Account overload has the same selector and return value as V2 Gauge, so the shared
  `Voter.claimRewardsAndLock(gauges, veTokenId, lockDuration)` batches V2 and CL gauges into one NFT.

LP position ids and veNFT ids belong to different NFT contracts. `veTokenId == 0` creates a
new timed lock owned by the account. Duration is seconds, rounded down to escrow's weekly boundary
and bounded by its four-year maximum. For an existing veNFT, duration must be zero and the account
must own it; approved operators cannot redirect rewards into a foreign NFT. Existing lock duration
and permanent status are preserved. Escrow's expired, team-lock and managed restrictions apply.
The reward token must equal escrow's underlying token. No user IRS approval is required.

Zero rewards create no NFT and trigger no hook. Out-of-range positions can yield zero while
in-range positions fund the aggregate lock. Existing target ownership/duration are validated even
when rewards are zero; new duration is validated by escrow only when funding a new lock.
Locking preserves the existing reward-growth and reserve accounting. Gauge approves escrow for
exactly the reward amount, then clears allowance before the callback.

## Callback

```solidity
function onClaim(uint256 tokenId, uint256 amountLocked, address user, address gauge) external;
```

Positive liquid claims pass `(0, 0, account, address(this))`. Locked claims pass the resulting
veNFT id and actual aggregate/single IRS amount deposited. Gauge is the caller; hook must check
`msg.sender == gauge` and authenticate the gauge against the protocol registry/version allowlist.
Use `Voter.poolForGauge(gauge)` or `CLGauge(gauge).pool()` for pool-specific policy.

Legacy Voter liquid claims invoke one callback per positive position. Account lock claims invoke
one callback per gauge, after aggregation. Repeated claims in the same block cannot pay twice.
Withdrawals automatically claim liquid IRS and therefore invoke the liquid callback too.

Claims and withdrawals are nonreentrant. Hook failures atomically revert rewards, pool checkpoints,
escrow changes and transfers; withdrawal failures also restore staking and NFT custody. A global
reverting hook can block claims and withdrawals wherever positive rewards are due. Team can repair
or disable it through Voter. Hooks receive no token allowance. Reward funding and policy remain
responsibilities of the future hook implementation.

## Deployment and verification

Existing gauges are immutable clones; changing a factory implementation does not update them.
New CLGauge requires the updated production Voter with `claimHook()`, including for liquid claims.
Deploy coordinated versions and use the protocol's factory/registry migration process. No onchain
transaction or deployment is part of this source change.

Tests deploy real CL pools, position manager and VotingEscrow. The 0.8.30 escrow is loaded from
its creation artifact, with its production libraries linked at test deployment time, avoiding
mixed compiler imports or committed bytecode. Production-Voter tests use the matching core Voter
artifact, including its shared hook and batch APIs. Build the updated core sources first:

```sh
(cd ../contracts && forge build --skip test --skip script)
forge test --match-path 'test/unit/{concrete,fuzz}/CLGauge/*.t.sol'
```

The narrow `../contracts/out` read permission permits loading these real dependency artifacts.
Set `ICARUS_CORE_ARTIFACTS` to use another artifact directory inside the workspace. CI checks out
core contracts in `.core-contracts`, builds them, and sets this variable. Merge the matching core
Voter change first, or configure repository variable `ICARUS_CORE_REF` to a ref containing it;
the default is `main`. A core version without the new APIs fails these integration tests.
Run full `forge test` for pool/periphery regressions.

The claim-and-lock suites cover ownership, escrow restrictions, zero/out-of-range rewards,
multi-position conservation, same-block repeated claims, callback ordering/reentrancy, and complete
claim/withdrawal rollback. Production-Voter tests cover later-created gauges and mixed V2/CL batches
funding one NFT, with authenticated per-gauge callback amounts and cleared escrow allowances.
