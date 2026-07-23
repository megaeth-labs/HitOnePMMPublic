# HitOne venue

HitOne is a perpetual-futures venue built around **fully isolated per-`(maker, token)`
sub-markets**. Users sign orders off-chain naming the exact **maker** they want as counterparty;
that maker submits the order on-chain and is the sole counterparty via its **own segregated
pool**. There is no order book and no taker role — the maker commits a fill price at submission
time and the contract enforces the user's signed slippage band.

**Maker registration is permissionless.** Any address can run a book on an owner-registered
token: it sets its own risk limits, funds its own pool, and pushes its own marks + funding rate.
Everything that defines a market — marks, funding index/rate, risk limits, open interest and the
collateral pool — is keyed by `(maker, token)`, so a maker (including a malicious one) can only
ever affect its own book. The owner's role shrinks to curating the token universe (the structural
tick/leverage/duration/cut grid) and the emergency `halter` set.

This document is written for someone building the **off-chain processes** that operate a maker
book (order intake, mark/funding pushing, liquidation, treasury). It covers the on-chain
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
| `HitOneAdmin.sol`     | Owner/maker/funder/halter admin, timelocked role changes, halt/unhalt, token/oracle config, per-maker pool funding + timelocked withdrawals. |
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
| **owner** | constructor / `transferOwnership` | Curates tokens (`setToken` structural grid, `setOracle`), `setWithdrawDelay`, queue/cancel the `halter` set, `cancelRoleChange`. **Cannot** register makers, touch any maker's pool, halt, or unhalt. |
| **maker** | **permissionless** — no registration | Any address, on any owner-registered token: `setRiskLimits` (its own), push marks (`setMark`/`setMarkAndRate`), submit orders naming itself (`openPosition`/`increasePosition`/`closePosition`), `liquidate` its own book, `setMakerFunder`. Each maker's marks/funding/risk/OI/pool are keyed `(maker, token)` and fully isolated. |
| **funder** | `setMakerFunder(maker, …)` — **self-set by the maker** | Per-maker treasury key. Fund / queue-withdraw / cancel-withdraw for **that maker's pool only**. Defaults to the maker itself when unset; once set, only the funder may rotate it (hot-maker / cold-funder split). |
| **halter** | `queueSetHalter(addr, allowed)` (owner, timelocked) | `halt`, `unhalt` (after cooldown), `setPausedNew`. **Multiple allowed** (`isHalter` set). Only halters may halt/unhalt — makers, funders and the owner cannot unless separately granted the halter role. |

**Role-change timelock.** The **only** owner role change is the halter set: `queueSetHalter` →
wait `roleChangeDelay()` (= **2 × `withdrawDelay`**, 12 h by default) → `executeRoleChange(id)`
(permissionless), or `cancelRoleChange(id)` (owner). Makers self-register and self-fund with no
timelock — isolation makes that safe, since a maker can only ever harm its own book.

Permissionless entry points: `expirePosition` (after max duration),
`executeWithdrawMakerPool` (after the delay), and `executeRoleChange` (after the delay).

Halt semantics:
- `halt()` (**halters only** — not makers, funders, or the owner) → sets `halted` and
  `whenNotHalted` blocks opens, increases, closes, marks, liquidation. It also stamps
  `haltedUntil = now + HALT_COOLDOWN` (**20 min**); calling again while halted pushes the
  window further out (halters can keep a halt live indefinitely).
- `unhalt()` (**halters only**) → lifts the halt, but reverts `HaltCooldownActive`
  until `block.timestamp >= haltedUntil`. Unhalting is always an explicit transaction — the
  halt never expires on its own. The owner cannot unilaterally unhalt, so a halt is a genuine
  brake against an adversarial owner: it can only be lifted by a halter, and the owner can only
  change the halter set through the timelock.
- `setPausedNew(true)` (owner or any halter) → `whenNotPausedNew` blocks **new opens and
  increases only** (venue-wide); closes/decreases and liquidation stay live so users can always exit.

---

## 3. Order lifecycle (the core off-chain flow)

1. **User signs** an EIP-712 `Order`. Domain: `name="HitOneMarket"`, `version="1"`,
   `chainId`, `verifyingContract` = the market address. Struct in `IHitOneMarket.Order`.
2. **Backend receives** the signed order + signature.
3. **Maker picks `fillPrice`** (1e18 USDM-wei) and submits via `openPosition` /
   `increasePosition` / `closePosition`. `msg.sender` must equal `order.maker` — the exact maker
   the user chose (else `WrongMaker`). No whitelist: any address can be a maker.
4. The contract verifies:
   - `msg.sender == order.maker` (else `WrongMaker`) — flow can't be stolen by another maker;
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
- **At most one active position per `(user, maker, token)`.** Opening a second against the same
  maker reverts `PositionExists`; use `increasePosition` to grow, `closePosition` (partial) to
  shrink. A user *can* hold separate positions against different makers on the same token.
- On increase, the order's `isLong` and `leverage` must match the live position (else
  `BadUserSig`), and `order.maker` must match (the position is keyed by maker).
- On close, `order.size <= position.size`. Equal size → full close; smaller → partial
  (size-down) settling pro-rata and leaving the remainder open.

---

## 4. Collateral model

Users hold **no internal balance**. They grant a USDM allowance to the market; collateral is
pulled from their wallet on open/increase and payouts are pushed back to their wallet on
close/decrease/expire. Each **maker keeps its own segregated pool** — `collateral[maker][token]`
— and is the counterparty to the positions it opens. A position stores its `maker` at open;
all its PnL, fees, losses, wipes and the winnings cut settle against **that** maker's pool only,
so one maker (or a rogue maker the owner adds) can never drain another maker's capital.

- On open: `collateral = markNotional / leverage` is pulled from the user. The open fee
  (`openFeeBps` of notional) is credited to the submitting maker's pool; the position stores
  `collateral − fee` and `maker = msg.sender`.
- `increasePosition` must be submitted by the position's **own** maker (else `WrongMaker`), so
  added exposure stays backed by the same pool.
- PnL flows against the position's maker pool: user profit is paid out of it (reverts
  `Insolvent` if that pool can't cover it), user loss is absorbed into it. Keep each pool funded.
- The house "winnings cut" (see §7) is credited back to the position's maker pool on profitable
  closes.

Per-maker treasury operations (each callable **only by `makerFunder[maker]`**):
- `fundMakerPool(maker, token, amount)` — the maker's funder deposits USDM.
- `queueWithdrawMakerPool(maker, token, amount, to)` → returns `id`; then
  `executeWithdrawMakerPool(id)` after `withdrawDelay` (**default 6 h**, owner-raisable to 48 h).
  `cancelWithdrawMakerPool(id)` is **funder-gated, not owner** — so an adversarial owner can't
  trap a maker's queued exit. Execution is permissionless once ready.

---

## 5. Marks + funding

Each maker pushes marks continuously and funding rates occasionally **to its own
`(msg.sender, token)` book** — marks, the mark ring, the funding index and the rate are all
per-maker. One maker's marks never affect another maker's positions (liquidation, funding or
expiry). Views take a `maker` argument: `marketOf(maker, token)`, `rateRingAt(maker, token, idx)`,
`reconstructAt(maker, token, entries)`.

- `setMark(token, newMark)` — push a new mark (1e18 USDM-wei) to your book, rate unchanged.
- `setMarkAndRate(token, newMark, newRate)` — push mark and a new funding rate to your book.

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

## 8. Parameters: token-level structural (owner) vs per-maker risk

**Structural** is token-level and owner-set via `setToken(token, Structural)` — one grid per
token, shared by every maker on it (so units stay coherent for the oracle). `priceTick == 0`
**deregisters** the token. **Risk** is per-`(maker, token)` and set by the maker itself via
`setRiskLimits(token, Risk)` — permissionless, and a maker's book is **inert until it sets risk**
(the un-set default leaves `maxPositionNotional == 0`, which blocks all opens). Read them back
with `structuralOf(token)` and `makerRiskOf(maker, token)`.

`Structural` (owner, infrequent):
- `priceTick` — min price step, 1e18 USDM-wei (e.g. `1e18` = $1).
- `sizeTick` — min size step, 1e18 asset-wei (e.g. `1e10` = 1 sat).
- `notionalScale` — **derived** = `priceTick * sizeTick / usdmDenom`; leave 0, it's computed.
- `minLeverage` / `maxLeverage` — bounds `[1, 10000]`.
- `maxPositionDuration` — `[1 h, 365 d]`; expiry clock.
- `cutIntercept` / `cutSlopeBps` / `maxCutBps` — winnings-cut ramp (`maxCutBps <= 5000`).

**Reference starting point (illustrative, not enforced).** These are *not* defaults the
contract fills in — `Structural` has no defaults, every field is required. This is a sane
BTC-like set to copy and then tune per token:

```solidity
ParamCatalog.Structural({
    priceTick:           1e18,      // $1 price step. Scale to the asset's price: a $2 token
                                    //   wants a much smaller tick (e.g. 1e15 = $0.001).
    sizeTick:            1e10,      // 1e-8 asset min size increment (~1 sat for an 18-dec asset).
    notionalScale:       0,         // leave 0 — derived = priceTick * sizeTick / usdmDenom.
    minLeverage:         500,       // 500x floor — this venue is built for high leverage.
    maxLeverage:         1000,      // 1000x ceiling.
    maxPositionDuration: 30 days,   // expiry clock; anyone can expirePosition past this.
    cutIntercept:        100e18,    // first $100 of profit is rake-free.
    cutSlopeBps:         1,         // +1 bp of cut rate per $1 of profit above the intercept …
    maxCutBps:           550        // … capped at 5.5%. (So the cap bites at ~$650 profit.)
})
```

Tuning notes:
- **priceTick × sizeTick must be divisible by `usdmDenom`** (10**usdm.decimals()) or `setToken`
  reverts `BadPriceTick`; the product also sets notional granularity, so don't make both huge.
- **Winnings cut**: for a flat rate instead of a ramp, set `cutIntercept = 0` and a large
  `cutSlopeBps` so `maxCutBps` is hit immediately. For no house cut at all, set all three to 0.
- **maxLeverage** is the main knob on how much adverse-move risk the maker pool absorbs per unit
  of collateral — treat it as a risk-budget decision, not a UX one.

`Risk` (per-`(maker, token)`, maker-set, frequent; zero → sensible default, but note a wholly
unset risk struct leaves `maxPositionNotional == 0` and blocks opens — set it before quoting):
- `openFeeBps` (`<= 1000`), `maxPositionNotional` (0 → 200 000e18),
  `maxOIGross` / `maxOISkew` (0 → unlimited).
- `linearScale` / `quadScale` are IsoMarket slippage knobs — **unused by HitOne** (fills come
  from the maker + slippage band), pass `type(uint256).max`.
- `maxDevBps` in this struct is **unused by HitOne** — the oracle band lives in the owner's oracle
  config (below), not per-maker, so a maker can't loosen it.

### Oracle band (owner-set per token — the context makers operate within)

`setOracle(token, feed, decimals, maxStale, maxDevBps)` (**owner**, optional; `feed == 0`
disables). It's the one price guardrail the owner defines for a token; every maker's marks on that
token are checked against the same feed and band, so a maker cannot widen it. On each mark push
(`setMark`/`setMarkAndRate`, open/close/liquidate) the contract checks
`|newMark − oraclePrice| * 10000 <= maxDevBps * oraclePrice` and staleness
(`block.timestamp <= updatedAt + maxStale`), reverting `MarkOutOfOracleBand` / `OracleStale` /
`OracleBadAnswer`. The intent is a **sanity band, not a precise price** — keep the mark from
drifting far enough to exploit anyone.

**RedStone on MegaETH** (see `script/hitone/RedStoneFeeds.sol` for per-chain addresses):
- Feeds are Chainlink `AggregatorV3`-compatible, so `setOracle` reads them directly — no glue.
- **RedStone runs the relayer** that keeps the price on-chain; HitOne only does a `view` read. You
  don't run a pusher, and there's no per-tx payload (that's the *pull* model, which HitOne doesn't
  use).
- Recommended (first version): **`maxDevBps = 100`** (1%) and **`maxStale = 6 h`** — the standard
  push feed's heartbeat. `maxStale` is a hard floor that must survive the worst case (a flat window
  with no 0.1% move); in practice the deviation trigger keeps updates far more frequent, so 6 h is
  fine. For a tighter *guaranteed* freshness bound later, ask RedStone for a shorter-heartbeat feed
  or use Bolt (same interface, same read cost). Feeds are USD-denominated (8-dec); to guard against
  a USDm de-peg, normalize by the `USDm-TWAP-60` feed.
- **Not yet timelocked.** `setOracle` (and `setToken`) take effect immediately; time-delaying the
  owner's token-context changes is a planned follow-up.

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
events (`MakerFunderSet`, `HalterSet`, `RoleChangeQueued`/`Executed`/`Cancelled`,
`WithdrawDelaySet`, `Halted`/`Unhalted`, `TokenSet`, `RiskLimitsSet` (indexed by `maker`),
`OracleSet`, maker-pool fund/withdraw (carry `maker`), `PausedNew`). `MarkPushed` and
`FundingRateChanged` are now indexed by `(maker, token)` — filter by maker to follow one book.
`PositionClosed` carries the gross `pnl` / `fundingPaid` / `makerCut` split;
`PositionView.realizedPnl` stores only the *effective* PnL, so reconstruct the split from the
event.

---

## 11. Off-chain processes to build (checklist)

0. **Maker onboarding** — a new maker self-registers on a token: `setRiskLimits(token, risk)`,
   optionally `setMakerFunder(maker, coldKey)`, fund the pool, push a first mark. No owner step.
1. **Order gateway** — verify user sigs off-chain (fail fast), pick `fillPrice`, submit with the
   maker key named in `order.maker`. Handle nonce/channel allocation and deadline windows.
2. **Mark + funding pusher** — push marks at a steady cadence (never twice in one ms; keep gaps
   under 4.095 s to preserve liquidation history; split moves > ±524 287 ticks; stay inside the
   oracle band). Update funding rate on demand — no rescaling on price moves.
3. **Liquidation engine** — track live `effPnl` vs `col`, submit `liquidate` batches (optionally
   with a fresh mark). Remember the 200-entry / sentinel walk-back limit.
4. **Expiry sweeper** — optional; permissionless `expirePosition` past max duration.
5. **Treasury** — keep each maker's segregated pool solvent (`fundMakerPool(maker, …)` from that
   maker's funder key); manage the timelocked withdrawal queue (`withdrawDelay`, 6–48 h).
6. **Indexer** — consume the events above; validate mark timing against `microTimestamp`.

---

## 12. Deployment

Constructor: `HitOneMarket(owner, usdm)` — sets the owner and caches USDM decimals. No initial
maker (registration is permissionless). EIP-712 domain is fixed to `("HitOneMarket", "1")`.

**Bring-up.** Owner side: deploy → `setToken` for each token → `queueSetHalter` → wait
`roleChangeDelay()` (12 h at the default 6 h `withdrawDelay`) → `executeRoleChange` → optionally
`transferOwnership`. Maker side (permissionless, any time after the token is registered):
`setRiskLimits` → optional `setMakerFunder` → `fundMakerPool` → `setMark`. The only timelocked
step is installing halters; makers need no owner involvement.

Scripts (`script/hitone/`): `DeployHitOne.s.sol` (owner bring-up + a self-registered maker),
`SimHitOneTrade.s.sol` (real on-chain open→close round trip — run it twice, it opens then closes),
and `RedStoneFeeds.sol` (per-chain oracle feed addresses + recommended band values).

**Contract-size note.** `HitOneMarket` runs close to the EIP-170 24 576-byte limit. `foundry.toml`
strips metadata (`bytecode_hash = "none"`, `cbor_metadata = false`) and `reconstructAt` was dropped
(reconstruct from the `MarkPushed`/`FundingRateChanged` event stream) to leave margin (~24.1 KB).
Adding surface area may re-breach the limit.
