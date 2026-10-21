---
read_when: Integrating CL mint-and-stake, authorizing third-party deposits, configuring gauge-factory helpers, or deploying updated gauges and LiquidityStakeHelper.
---

# Mint and stake in one transaction

`CLGauge` supports both `deposit(tokenId)` and `deposit(tokenId, recipient)`.
The original selector retains its behavior and delegates to shared internal logic with
`msg.sender` as recipient. Both entrypoints are protected against reentrancy.

Caller must own the NFT and approve Gauge. Operators cannot deposit another owner's NFT.
The two-argument overload transfers staking rights to the nonzero recipient: Gauge owns
the NFT while staked, but the recipient can claim emissions and withdraw the NFT directly.
The depositor retains no withdrawal rights unless also the recipient. Pre-deposit accrued
trading fees go to the caller; subsequent rewards/withdrawal proceeds follow the recipient.
`Deposit.user` identifies the recipient. Existing pool matching and live-gauge checks remain.

## Third-party deposit authorization

Self-deposits remain available to every NFT owner through either overload. When
`recipient != msg.sender`, Gauge requires its creating `CLGaugeFactory` to return
`isWhitelisted(msg.sender) == true`. The whitelist starts empty. The factory's retained
deployment owner or the current `VotingEscrow(Voter.ve()).team()` can call `setWhitelisted(account, allowed)`
to grant or revoke permission. Configuring the NFT manager does not clear the owner.
This whitelist is separate from private-pool/private-manager permissions.

Whitelisted helpers are trusted to authenticate the recipient themselves, for example
by requiring the recipient to be their caller or checking recipient authorization.
The factory checks the immediate caller only; it does not check recipient consent.
An unrestricted helper would let attackers deposit dust NFTs for arbitrary victims
and grow their account claim costs despite this whitelist.

`LiquidityStakeHelper` requires `MintParams.recipient == msg.sender`: each caller can
stake only for itself. A different recipient reverts with `NA`; zero and the helper
itself remain invalid with `ZA`. The helper still needs a gauge-factory whitelist
entry because Gauge sees the helper as its caller and the helper's caller as recipient.

Both account claim paths iterate all positions: Voter-only `getReward(account)` and
`getRewardAndLock(account, veTokenId, lockDuration)`. Unsolicited deposits can make
these claims too expensive. Single-position liquid/locked claims, single-position
withdrawals (including their automatic liquid reward claim), and new deposits do
not iterate the account's stake list and remain available under their existing checks.
Whitelist revocation restricts future third-party deposits; it does not restrict
claims, withdrawals or self-deposits.

## Helper

Deploy `contracts/periphery/LiquidityStakeHelper.sol` with the trusted NFT position manager.
The helper derives its immutable factory and Voter from that manager. It authenticates
the existing pool's live Voter-registered gauge against that manager, pool and Voter.

1. Approve desired token0/token1 amounts to the helper (separate transactions unless already approved).
2. Call `mintAndStake(MintParams, minLiquidity)`. Use standard manager mint parameters:
   sorted token addresses, tick spacing, exact lower/upper ticks, desired/max inputs,
   token minimums, recipient and deadline. Set recipient to the immediate caller of
   the helper; a forwarding contract therefore receives the staking rights itself.
   `sqrtPriceX96` must be zero: pool and gauge
   must already exist. `minLiquidity` adds a minimum on the minted liquidity itself.
3. Helper pulls inputs, mints to itself, approves the NFT to Gauge, deposits for the
   caller, and refunds unused inputs to caller. Returns token id, liquidity,
   amount0 and amount1; emits `LiquidityStaked`.
4. Recipient uses Gauge's normal claims and withdrawal APIs. Helper has no ongoing role.

Supports one-sided out-of-range positions and multiple independent calls/positions.
Inputs are ERC20 only; wrap native currency first. Fee-on-transfer and rebasing tokens
are unsupported. No swaps, permits or pool creation. For private managers, whitelist the
helper unless public liquidity is enabled; the manager itself must remain factory-whitelisted.
Whitelisting the helper exposes its mint API to all callers, so use it only where public
access through that helper is intended.

All operations revert together on failure. Exact manager allowances are cleared after mint;
the NFT's single-token approval clears on transfer to Gauge. There are no permanent NFT
operator approvals. Refunds use only this call's unused inputs; preexisting donations stay
untouched. The helper has no owner or rescue function: do not send tokens/NFTs directly.
The helper is nonreentrant and relies on the configured manager/factory/Voter as trusted
deployment dependencies.

## Deployment boundary

Existing gauge clones are immutable and cannot acquire this overload or its authorization
check. Deploy a compatible updated gauge factory and gauges using the updated
implementation before integrating guarded helpers. Deploying an
implementation alone does not update a factory's configured implementation or existing
pool/gauge registrations. This change performs no deployment, gauge migration or Voter
registration. Calling the helper against a gauge without the recipient overload reverts
atomically. An existing gauge with the unrestricted overload retains that behavior.

Existing helper deployments are immutable and retain their original recipient policy.
Redeploy the guarded helper and whitelist its new address in each applicable gauge
factory. Do not whitelist legacy helpers with unrestricted recipients; revoke any such
entries when migrating.

## Verification

```sh
forge test --match-path 'test/unit/concrete/LiquidityStakeHelper/*.t.sol'
forge test --match-path 'test/unit/concrete/CLGauge/*.t.sol'
```
