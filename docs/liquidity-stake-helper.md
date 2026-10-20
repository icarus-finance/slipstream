---
read_when: Integrating CL mint-and-stake, depositing an NFT for another account, or deploying updated gauges and LiquidityStakeHelper.
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

## Helper

Deploy `contracts/periphery/LiquidityStakeHelper.sol` with the trusted NFT position manager.
The helper derives its immutable factory and Voter from that manager. It authenticates
the existing pool's live Voter-registered gauge against that manager, pool and Voter.

1. Approve desired token0/token1 amounts to the helper (separate transactions unless already approved).
2. Call `mintAndStake(MintParams, minLiquidity)`. Use standard manager mint parameters:
   sorted token addresses, tick spacing, exact lower/upper ticks, desired/max inputs,
   token minimums, recipient and deadline. `sqrtPriceX96` must be zero: pool and gauge
   must already exist. `minLiquidity` adds a minimum on the minted liquidity itself.
3. Helper pulls inputs, mints to itself, approves the NFT to Gauge, deposits for the
   requested recipient, and refunds unused inputs to caller. Returns token id, liquidity,
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

Existing gauge clones are immutable and cannot acquire this overload. Deploy updated
gauges using the updated implementation before integrating the helper. Deploying an
implementation alone does not update a factory's configured implementation or existing
pool/gauge registrations. This change performs no deployment, gauge migration or Voter
registration. Calling the helper against an older gauge reverts atomically.

## Verification

```sh
forge test --match-path 'test/unit/concrete/LiquidityStakeHelper/*.t.sol'
forge test --match-path 'test/unit/concrete/CLGauge/*.t.sol'
```
