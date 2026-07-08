# HitOne venue

HitOne is a permissioned perpetual-futures venue. Users sign orders off-chain; a
whitelisted **maker** submits them on-chain and is the counterparty to every position via a
single shared **maker pool**. There is no order book and no taker role — the maker commits a
fill price at submission time and the contract enforces the user's signed slippage band.

This document is written for someone building the **off-chain processes** that operate the
venue (order intake, mark/funding pushing, liquidation, treasury). It covers the on-chain
interface, the units/scaling conventions, the settlement and funding math, and the operational
gotchas that will bite an operator if ignored.

---

## 1. Architecture

The contract is split into an inheritance tree of abstract contracts so each concern reads
end-to-end in one file. Storage lives in exactly one place.

| File | Role |
|---|---|
| `HitOneStorage.sol`   | All storage, constants, immutables, modifiers, tick↔wei helpers. Single source of the storage layout. |
| `HitOneOrders.sol`    | EIP-712 order digest, signature/nonce verification, slippage-band check. |
| `HitOneMarks.sol`     | Mark + funding-rate push logic, oracle-band check, HP-timestamp read, mark-domain views (`marketOf`, `reconstructAt`). |
| `HitOnePositions.sol` | Position lifecycle: open, increase, close/decrease, expire, settle, liquidate, position views. |
| `HitOneAdmin.sol`     | Owner/maker/funder/halter admin, halt/unhalt, token/oracle config, maker-pool funding + timelocked withdrawals. |
| `HitOneMarket.sol`    | Concrete contract; just the constructor + inheritance (`HitOnePositions`, `HitOneAdmin`). |
| `IHitOneMarket.sol`   | Full external interface: events, errors, structs, function signatures. **Start here when integrating.** |

Shared libraries in `../common/`:

| Module | Purpose |
|---|---|
| `ParamCatalog.sol`         | Per-token `Structural` + `Risk` params, validation, and the `houseCut` ramp. |
| `MarkRing.sol`             | Packed ring buffers: 200-entry mark history (int20 priceDelta + uint12 ms) and a parallel funding-rate ring. |
| `FundingIndex.sol`         | Funding accumulator math (`effectiveAtPct` / `stepBackPct`). |
| `IAggregatorV3.sol`        | Chainlink-shape oracle interface for the optional deviation band. |
| `IHighPrecisionTimestamp.sol` | MegaETH µs wall-clock system contract interface. |

`FundingIndex`, `MarkRing`, `ParamCatalog` and the oracle interface are shared with the
IsoMarket venue; HitOne uses the *percentage* funding helpers (`*Pct`), IsoMarket uses the
absolute ones.

---

## 2. Roles

| Role | Set by | Powers |
|---|---|---|
| **owner** | constructor / `transferOwnership` | `setToken`, `setOracle`, `setMaker`, `setFunder`, `setHalter`, `unhalt`, `cancelWithdrawMakerPool`. Overall admin. |
| **maker** | `setMaker` (owner) | Submit user orders (`openPosition`/`increasePosition`/`closePosition`), push marks (`setMark`/`setMarkAndRate`), `liquidate`, `setRiskLimits`. Multiple makers allowed. Self-revoke via `renounceMaker`. |
| **funder** | `setFunder` (owner) | Fund and queue maker-pool withdrawals (`fundMakerPool` / `queueWithdrawMakerPool`). Single address. |
| **halter** | `setHalter` (owner) | `halt`, `unhalt` (after cooldown), `setPausedNew`. Single address. |

Permissionless entry points: `expirePosition` (after max duration) and
`executeWithdrawMakerPool` (after the timelock).

Halt semantics:
- `halt()` (any **maker**, the **funder**, the **halter**, or **owner**) → sets `halted` and
  `whenNotHalted` blocks opens, increases, closes, marks, liquidation. It also stamps
  `haltedUntil = now + HALT_COOLDOWN` (**20 min**); calling again while halted pushes the
  window further out (halters can keep a halt live indefinitely).
- `unhalt()` (**owner** or **halter** only) → lifts the halt, but reverts `HaltCooldownActive`
  until `block.timestamp >= haltedUntil`. Unhalting is always an explicit transaction — the
  halt never expires on its own.
- `setPausedNew(true)` (owner, halter, or maker) → `whenNotPausedNew` blocks **new opens and
  increases only**; closes/decreases and liquidation stay live so users can always exit.

---

## 3. Order lifecycle (the core off-chain flow)

1. **User signs** an EIP-712 `Order`. Domain: `name="HitOneMarket"`, `version="1"`,
   `chainId`, `verifyingContract` = the market address. Struct in `IHitOneMarket.Order`.
2. **Backend receives** the signed order + signature.
3. **Maker picks `fillPrice`** (1e18 USDM-wei) and submits via `openPosition` /
   `increasePosition` / `closePosition`. The maker's key is `msg.sender` and must be
   whitelisted.
4. The contract verifies:
   - `block.timestamp <= order.deadline` (else `OrderExpired`);
   - `!nonceUsed[user][channel][nonce]` then marks it used (`NonceAlreadyUsed`);
   - `ECDSA.recover(digest) == order.user` (else `BadUserSig`);
   - slippage band: `|fillPrice − targetPrice| * 10000 <= targetPrice * maxSlippageBps`
     (else `SlippageExceeded`);
   - `order.isOpen` matches the action (open/increase require `true`, close requires `false`).

`Order` fields (see `IHitOneMarket`): `user, token, isLong, isOpen, size (1e18 asset-wei),
leverage (ignored on close), targetPrice (1e18), maxSlippageBps, deadline, channel, nonce`.

Nonces are namespaced `(user, channel, nonce)` and single-use — `channel` lets the backend run
independent nonce lanes per user (e.g. one per session/device). Emits `NonceUsed`.

Constraints the backend must respect:
- **At most one active position per `(user, token)`.** Opening a second reverts
  `PositionExists`; use `increasePosition` to grow, `closePosition` (partial) to shrink.
- On increase, the order's `isLong` and `leverage` must match the live position (else
  `BadUserSig`).
- On close, `order.size <= position.size`. Equal size → full close; smaller → partial
  (size-down) settling pro-rata and leaving the remainder open.

---

## 4. Collateral model

Users hold **no internal balance**. They grant a USDM allowance to the market; collateral is
pulled from their wallet on open/increase and payouts are pushed back to their wallet on
close/decrease/expire. Only the **maker pool** (`MAKER_POOL == address(0)`) keeps an internal
`collateral[...]` balance.

- On open: `collateral = markNotional / leverage` is pulled from the user. The open fee
  (`openFeeBps` of notional) is credited to the maker pool; the position stores
  `collateral − fee`.
- PnL flows against the maker pool: user profit is paid out of the pool (reverts `Insolvent`
  if the pool can't cover it), user loss is absorbed into the pool. Keep the pool funded.
- The house "winnings cut" (see §7) is credited back to the maker pool on profitable closes.

Maker-pool treasury operations:
- `fundMakerPool(token, amount)` — funder deposits USDM.
- `queueWithdrawMakerPool(token, amount, to)` → returns `id`; then
  `executeWithdrawMakerPool(id)` after `MAKER_POOL_WITHDRAW_DELAY` (**48 h**). `owner` can
  `cancelWithdrawMakerPool(id)` during the delay. Execution is permissionless once ready.

---

## 5. Marks + funding

The maker pushes marks continuously and funding rates occasionally.

- `setMark(token, newMark)` — push a new mark (1e18 USDM-wei), rate unchanged.
- `setMarkAndRate(token, newMark, newRate)` — push mark and a new funding rate.

### Funding rate encoding (important)

`newRate` is a **signed fixed-point fraction per second**, not a price-scaled amount:

```
real_fraction_per_sec = newRate / (100 * 2**63)      // PCT_SCALE = 100 << 63
```

The full `int64` range spans **±1%/sec**, so the rate is inherently hard-capped — there is no
larger representable value and no explicit bound check. The absolute USDM funding is derived at
accrual time as `fraction × mark`, so **the effective rate tracks the mark automatically — the
maker does NOT rescale it when price moves.** Positive rate → longs pay shorts; negative →
shorts pay longs.

Example: `0.01%/hour ≈ (1e-4 / 3600) * 100 * 2**63 ≈ 2.56e13`.

The funding index integrates `fraction/sec × mark` over time. Positions checkpoint the index at
open and pay the delta at close/decrease/liquidation. Because the index stays in price-scaled
units, settlement divides by `SCALE (1e18)` to land in USDM-wei — identical to a
price-denominated funding model.

### Mark ring

Every push (after the first) records a packed entry into a 200-slot ring
(`MarkRing`): a 20-bit signed `priceDelta` in **tick units** and a 12-bit `timeDelta` in
**milliseconds**. A parallel ring stores the funding rate active during each interval. This
history powers liquidation walk-back (§6) and `reconstructAt`.

Operator constraints on pushes:
- **`MarkSameSlot`**: two pushes in the same HP millisecond revert. Rate-limit accordingly.
- **`MarkDeltaTooLarge`**: a single move larger than ±524 287 ticks can't be packed. For large
  jumps, push intermediate marks. (Sentinels are written automatically for *time* gaps
  > 4.095 s, not for price jumps.)
- **`BadMark`**: `newMark` must be a nonzero multiple of `priceTick`.
- Oracle band (if a feed is configured, §8): pushes revert on stale/out-of-band prices.

`MarkPushed` carries `microTimestamp` — MegaETH's µs wall-clock (system contract
`0x6342…0002`), or `block.timestamp × 1e6` as a fallback — so off-chain consumers can validate
each mark was posted at a plausible wall-clock time.

---

## 6. Liquidation

A position is liquidatable when effective PnL (gross PnL − funding owed) `<= −collateral`.

Two paths:
- **On close**: `closePosition` first walks the mark ring back from now to the position's
  `openTime`. If the position *would have been* liquidatable at any historical mark in that
  window, the close instead **wipes** the position (all collateral to the maker pool, no
  payout). This stops a user from "escaping" a liquidation by closing at a favorable current
  mark after an adverse spike.
- **Standalone**: `liquidate(token, newMark, positionIds[])`. If `newMark != 0` it is pushed
  first (same as `setMark`, oracle band included), then each id is walk-back-checked and wiped
  if liquidatable. Reverts `NoneLiquidated` if none qualified. Non-matching/closed ids are
  skipped, so batching is safe.

Walk-back caveats the liquidation engine must know:
- It only sees the last **200** ring entries and **stops at a sentinel** (a > 4.095 s gap). If
  marks aren't pushed frequently enough, liquidation history is lost. **Push marks regularly.**
- `increasePosition` resets `openTime`, which moves the walk-back floor forward (the blended
  entry only becomes valid at that point) and restarts the max-duration expiry clock.

`expirePosition(id)` is permissionless once `openTime + maxPositionDuration` has elapsed; it
force-closes at the current mark.

---

## 7. Settlement math

For a closed slice of `size` (asset units) carrying `col` collateral, at `fillPrice`:

```
pnl         = (isLong ? +1 : −1) * (fillPrice − entry) * size * notionalScale     // USDM-wei
fundingPaid = fundingDelta * (size * sizeTick) / SCALE                            // USDM-wei
effPnl      = pnl − fundingPaid
```

- If `effPnl > 0`: `makerCut = houseCut(effPnl, ...)`, `payout = col + effPnl − makerCut`. The
  cut is credited to the maker pool.
- If `effPnl <= 0`: `payout = max(0, col − loss)`; the loss (capped at `col`) accrues to the
  maker pool.

**House "winnings cut" ramp** (`ParamCatalog.houseCut`): no cut until profit clears
`cutIntercept`; above it the cut *rate* ramps `cutSlopeBps` per whole USDM of profit past the
intercept, capped at `maxCutBps`; the rate is then applied to the **whole** effPnl. This is a
per-token linear ramp, not a flat rate.

Partial close (`_settleDecrease`) settles a pro-rata slice (`col`, `notional`, OI all scale by
`closeSize / size`); entry price, funding checkpoint, and leverage of the remainder are
unchanged.

Increase blends size-weighted: new entry and funding checkpoint are the size-weighted average
of old and added; the open fee and OI/notional exposure are charged only on the added size.

---

## 8. Per-token parameters

Set via `setToken(token, TokenParams)` (owner) and `setRiskLimits(token, Risk)` (maker).
Setting `structural.priceTick == 0` in `setToken` **deregisters** the token.

`Structural` (owner, infrequent):
- `priceTick` — min price step, 1e18 USDM-wei (e.g. `1e18` = $1).
- `sizeTick` — min size step, 1e18 asset-wei (e.g. `1e10` = 1 sat).
- `notionalScale` — **derived** = `priceTick * sizeTick / usdmDenom`; leave 0, it's computed.
- `minLeverage` / `maxLeverage` — bounds `[1, 10000]`.
- `maxPositionDuration` — `[1 h, 365 d]`; expiry clock.
- `cutIntercept` / `cutSlopeBps` / `maxCutBps` — winnings-cut ramp (`maxCutBps <= 5000`).

`Risk` (maker, frequent; zero → sensible default):
- `openFeeBps` (`<= 1000`), `maxPositionNotional` (0 → 200 000e18),
  `maxOIGross` / `maxOISkew` (0 → unlimited), `maxDevBps` (0 → 3; oracle band).
- `linearScale` / `quadScale` are IsoMarket slippage knobs — **unused by HitOne** (fills come
  from the maker + slippage band), pass `type(uint256).max`.

Optional oracle: `setOracle(token, feed, decimals, maxStale)`. When a `feed` is set, every mark
push checks `|newMark − oraclePrice| * 10000 <= maxDevBps * oraclePrice` and staleness
(`block.timestamp <= updatedAt + maxStale`), reverting `MarkOutOfOracleBand` / `OracleStale` /
`OracleBadAnswer`. No feed → checks skipped.

Risk caps enforced at open/increase: `PositionNotionalCap`, `OIGrossCap`, `OISkewCap`.

---

## 9. Units & scaling cheat-sheet

| Quantity | External (API/events) | Internal storage |
|---|---|---|
| Price | 1e18 USDM-wei | `priceUnits = price / priceTick` (uint128) |
| Size  | 1e18 asset-wei | `sizeUnits = size / sizeTick` (uint128) |
| Notional / collateral / payout | USDM-wei (1e18 scale) | USDM-wei |
| Funding rate | `fraction/sec × (100·2⁶³)` (int64) | same |
| Funding index | price-scaled; ÷1e18 → USDM-wei | int128 |
| Mark timeDelta (ring) | ms | 12-bit, 1 ms units |
| Mark priceDelta (ring) | tick units | 20-bit signed |

`notional = priceUnits * sizeUnits * notionalScale` (USDM-wei). All events/views emit
1e18-scaled values; tick compression is internal only.

---

## 10. Events to index

`MarkPushed`, `FundingRateChanged`, `NonceUsed`, `PositionOpened`, `PositionIncreased`,
`PositionDecreased`, `PositionClosed`, `PositionLiquidated`, `PositionExpired`, plus admin
events (`MakerSet`, `TokenSet`, `RiskLimitsSet`, `OracleSet`, maker-pool fund/withdraw,
`PausedNew`). `PositionClosed` carries the gross `pnl` / `fundingPaid` / `makerCut` split;
`PositionView.realizedPnl` stores only the *effective* PnL, so reconstruct the split from the
event.

---

## 11. Off-chain processes to build (checklist)

1. **Order gateway** — verify user sigs off-chain (fail fast), pick `fillPrice`, submit with the
   maker key. Handle nonce/channel allocation and deadline windows.
2. **Mark + funding pusher** — push marks at a steady cadence (never twice in one ms; keep gaps
   under 4.095 s to preserve liquidation history; split moves > ±524 287 ticks; stay inside the
   oracle band). Update funding rate on demand — no rescaling on price moves.
3. **Liquidation engine** — track live `effPnl` vs `col`, submit `liquidate` batches (optionally
   with a fresh mark). Remember the 200-entry / sentinel walk-back limit.
4. **Expiry sweeper** — optional; permissionless `expirePosition` past max duration.
5. **Treasury** — keep the maker pool solvent (`fundMakerPool`); manage the 48 h timelocked
   withdrawal queue.
6. **Indexer** — consume the events above; validate mark timing against `microTimestamp`.

---

## 12. Deployment

Constructor: `HitOneMarket(owner, maker, usdm)` — sets the owner, whitelists an initial maker,
and caches USDM decimals. EIP-712 domain is fixed to `("HitOneMarket", "1")`.

`script/hitone/DeployHitOne.s.sol` is a reference testnet deploy: it deploys the market, seeds
USDM + a market token if not supplied, registers the token, temporarily self-grants maker to
seed the pool and push an initial mark, then revokes and hands ownership to `MM_OWNER`. Env
vars are documented at the top of that script.
