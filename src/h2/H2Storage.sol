// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { IH2Market } from "./IH2Market.sol";
import { IH2Oracle } from "./IH2Oracle.sol";
import { IAggregatorV3 } from "../common/IAggregatorV3.sol";
import { IBuilderRegistry } from "./IBuilderRegistry.sol";
import { IHighPrecisionTimestamp } from "../common/IHighPrecisionTimestamp.sol";
import { FundingIndex } from "../common/FundingIndex.sol";
import { ParamCatalog } from "../common/ParamCatalog.sol";

/// @title H2Storage
/// @notice Shared storage layout, constants, immutables, modifiers and helpers for the H2
/// exchange. All state lives here so the layout is unambiguous across the inheritance tree.
///
/// There is deliberately NO Ownable, no halter, no pause and no timelock anywhere — the
/// contract is immutable and ownerless. A market's frozen parameters and its oracles are
/// the only authorities. The treasury is a permissionless share vault: nobody has any role
/// over it — not even the market creator.
abstract contract H2Storage is IH2Market, ReentrancyGuard, EIP712 {
    uint256 internal constant UNITS_CAP = 1 << 96;
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant WAD = 1e18; // 1e18 fixed-point (share-price scale)
    /// @dev The ring's sentinel gap in ms (MarkRing.GAP_MAX_UNITS × GAP_UNIT_MS = 4095 × 1).
    /// A mark older than this sits across a discontinuity the walk-back cannot replay.
    uint256 internal constant MARK_RING_GAP_MAX_MS = 4_095;

    /// @dev MegaETH high-precision-timestamp system contract (µs since epoch).
    address internal constant HP_TIMESTAMP =
        0x6342000000000000000000000000000000000002;

    bytes32 internal constant ORDER_TYPEHASH =
        keccak256(
            "Order(address user,uint256 marketId,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
            "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce,"
            "address builder,uint256 builderFeePpm)"
        );

    IERC20  public immutable override usdm;
    uint256 internal immutable _usdmDenom;
    IH2Oracle internal immutable _oracle;

    /// @dev Order-driven fee/cut credit routing: the builder + its per-order rate. Threaded
    /// from the signed order to every fee site so a close can carry a different builder than
    /// the open (users are never locked to one). `feePpm == 0` or an unregistered builder ⇒
    /// no cut (the vault keeps it).
    struct BuilderRef {
        address builder;
        uint256 feePpm;
    }

    // ---- markets (all frozen at createMarket) ----

    mapping(uint256 => FeeParams)    internal _fees;
    mapping(uint256 => RiskParams)   internal _risk;
    mapping(uint256 => OracleParams) internal _oracles;
    mapping(uint256 => SpreadParams) internal _spread;
    mapping(uint256 => address) internal _creatorOf;
    mapping(uint256 => address) internal _tokenOf;
    /// @notice Per-market builder registry (frozen at createMarket; 0 = builder codes disabled).
    /// The eligibility criteria live in that external contract, not here, so they can change by
    /// pointing a new market at a new registry. See IBuilderRegistry.
    mapping(uint256 => address) internal _builderRegistry;
    uint256 public override nextMarketId;

    // ---- builder codes (accrual only; eligibility lives in the per-market registry) ----

    /// @notice A builder's accrued, claimable fees (USDM). The market holds and pays these;
    /// the registry only gates who may accrue them.
    mapping(address => uint256) public override builderOwed;

    // ---- positions ----

    /// @notice Packed to 7 slots (slot 6 holds `lastActionBlock`). `realizedPnl` stores the
    /// EFFECTIVE PnL (pnl − funding − close fee); the split is recoverable from the close events.
    struct Position {
        // Slot 0
        address user;     // 20
        uint64  openTime; // 8 — resets on increase (walk-back floor)
        uint16  leverage; // 2
        bool    isLong;   // 1
        bool    closed;   // 1
        // Slot 1
        uint64  marketId;
        uint64  closeTime;
        uint64  expiresAt; // fixed at FIRST open; increases reset openTime but never this
        uint64  openMs;    // HP-clock open stamp: the anti-stale-mark predicate compares it
                           // against the FEED's lastPushMs like-for-like (fallback fills
                           // publish nothing, so the feed's mark can predate the position)
        // Slot 2
        uint128 entryPrice; // priceUnits
        uint128 size;       // sizeUnits
        // Slot 3
        uint128 closePrice; // priceUnits
        uint128 col;        // USDM-wei
        // Slot 4
        int128  fundingCheckpoint;
        int128  realizedPnl;
        // Slot 5
        uint128 notionalAtOpen; // USDM-wei
        uint128 makerCutPaid;   // winnings cut (name kept for continuity)
        // Slot 6
        uint64  lastActionBlock; // block.number of the last user mutation (open/increase/
                                 // decrease); one adjustment per block, so a convex size-fee
                                 // curve can't be dodged by chunking within one block
    }
    mapping(uint256 => Position) internal _positions;
    uint256 public override nextPositionId;

    /// @notice One active position per (user, market).
    mapping(address => mapping(uint256 => uint256)) public override activePositionId;
    /// @notice usedNonce[user][channel][nonce].
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public override nonceUsed;

    mapping(uint256 => uint256) internal openInterestLong;
    mapping(uint256 => uint256) internal openInterestShort;

    // ---- treasury: permissionless share vault (see TREASURY_DESIGN.md) ----

    /// @notice One share vault per market. `poolAssets` is the USDM backing the shares
    /// (all trading P&L flows through it after the oracle rake); a share is worth
    /// `poolAssets / totalShares`. `rakeOwed` is the feed operator's accrued cut,
    /// claimable via `claimRake`; `rakePpm` is that cut, cached from the primary feed at
    /// createMarket. Shares are internal, non-transferable balances.
    struct Vault {
        // Slot 0
        uint128 poolAssets;   // USDM backing the shares (post-rake)
        uint128 rakeOwed;     // feed operator's accrued rake, claimable
        // Slot 1
        uint256 totalShares;
        // Slot 2
        uint32  rakePpm;      // cached from the primary feed at createMarket
    }
    mapping(uint256 => Vault) internal _vault;
    /// @notice shares[marketId][user] — internal, non-transferable.
    mapping(uint256 => mapping(address => uint256)) internal _shares;

    /// @notice A pending unstake: `shares` frozen out at `unlockAt`. Those shares STAY in
    /// the pool and keep earning + bearing P&L until `withdraw` burns them (the cooldown is
    /// pure exit friction, not a dodge). One pending request per (market, user).
    struct Unstake {
        uint256 shares;
        uint64  unlockAt;
    }
    mapping(uint256 => mapping(address => Unstake)) internal _unstake;

    /// @notice Per-side running aggregates of OPEN positions, for the marked-to-market NAV
    /// (see `_mtmValue`). `sumSize` = Σ size (sizeUnits); `sumEntryW` = Σ entryPrice·size;
    /// `sumCheckW` = Σ fundingCheckpoint·size (signed). Maintained O(1) on every
    /// open/increase/decrease/close/wipe so the NAV can value open positions without
    /// iterating them. Bounded by the market's OI caps (another reason to set real
    /// `maxOIGross`), but kept in full-width 256-bit to never silently wrap.
    struct OpenAgg {
        uint256 sumSize;
        uint256 sumEntryW;
        int256  sumCheckW;
    }
    mapping(uint256 => mapping(bool => OpenAgg)) internal _openAgg;

    // ---- owed winnings (graceful degradation: a winning close pays what's liquid now and
    //      enqueues the shortfall, senior to LPs, claimable as the pool refills) ----

    /// @notice One owed entry = the unpaid part of a winning close. `start` is the cumulative
    /// `owedTail` at enqueue time; `amount` the shortfall; `claimed` what's been paid out of it.
    /// FIFO is enforced purely by `start`: an entry is fundable only once the pool has covered
    /// everything enqueued before it, so claim order never matters (no race).
    struct OwedEntry {
        address user;    // 20
        uint128 start;   // cumulative owedTail at enqueue
        uint128 amount;  // shortfall owed
        uint128 claimed; // paid so far
    }
    /// @notice Per-market owed queue + the owner's lookup of its entry ids, and the two
    /// monotonic cumulative counters that make the funded frontier O(1): `owedTail` = Σ ever
    /// enqueued, `owedHead` = Σ ever paid; `outstanding = owedTail − owedHead`.
    mapping(uint256 => OwedEntry[]) internal _owedQueue;
    mapping(uint256 => mapping(address => uint256[])) internal _userOwed;
    mapping(uint256 => uint256) internal owedTail;
    mapping(uint256 => uint256) internal owedHead;

    /// @dev Cap on how many of a user's owed entries one open/increase auto-draws as collateral;
    /// beyond it the remainder comes from the wallet (claim the rest via `claimWinnings`). Gas bound.
    uint256 internal constant MAX_OWED_DRAW = 8;

    constructor(address usdm_, address oracle_) {
        if (usdm_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        usdm = IERC20(usdm_);
        _oracle = IH2Oracle(oracle_);
        uint256 dec = uint256(IERC20Metadata(usdm_).decimals());
        // Funding settles ÷1e18 while notional settles ÷usdmDenom; the two land in the
        // same unit only for an 18-decimal settlement token. Refuse any other rather than
        // mis-scale funding silently — the contract is immutable.
        if (dec != 18) revert BadMarketParams();
        _usdmDenom = 10 ** dec;
    }

    function oracle() external view override returns (address) {
        return address(_oracle);
    }

    // ---- clocks ----

    /// @dev µs wall-clock from MegaETH's system contract; block.timestamp fallback so
    /// nothing bricks on the read (non-MegaETH chains, tests).
    function _microTimestamp() internal view returns (uint256) {
        (bool ok, bytes memory ret) = HP_TIMESTAMP.staticcall(
            abi.encodeWithSelector(IHighPrecisionTimestamp.timestamp.selector)
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return uint256(block.timestamp) * 1_000_000;
    }

    /// @dev Feed timestamps arrive on three scales (MegaETH RedStone pushes µs, pull
    /// payloads ms, Chainlink-shape feeds s); normalize by magnitude before any staleness
    /// comparison. Bands unambiguous until year ~5138.
    function _updatedAtSecs(uint256 t) internal pure returns (uint256) {
        if (t > 1e14) return t / 1_000_000;
        if (t > 1e11) return t / 1_000;
        return t;
    }

    // ---- marked-to-market NAV ----

    /// @dev Add an opening slice to its side's open-position aggregates.
    function _openAggAdd(uint256 marketId, bool isLong, uint256 size, uint256 entry, int256 check) internal {
        OpenAgg storage a = _openAgg[marketId][isLong];
        a.sumSize   += size;
        a.sumEntryW += entry * size;
        a.sumCheckW += check * int256(size);
    }

    /// @dev Remove a slice from its side's aggregates — a full close, a decrease portion, a
    /// liquidation wipe, or the OLD state of an increase. Uses the STORED (rounded) entry and
    /// checkpoint so the aggregate tracks exactly what settlement will compute.
    function _openAggSub(uint256 marketId, bool isLong, uint256 size, uint256 entry, int256 check) internal {
        OpenAgg storage a = _openAgg[marketId][isLong];
        a.sumSize   -= size;
        a.sumEntryW -= entry * size;
        a.sumCheckW -= check * int256(size);
    }

    /// @dev One side's unrealized effective PnL (price PnL − own-side funding) aggregated over its
    /// open positions, mirroring `_settleSlice`. Price PnL is exact; the funding term divides the
    /// summed numerator once (vs once per position in `_settleSlice`), so a multi-position pool's
    /// funding differs by < 1 wei per position in the SCALE division — negligible, and exact for a
    /// single position. Positive ⇒ traders up ⇒ the pool owes it.
    function _sideEffPnl(uint256 marketId, bool isLong, uint256 markUnits, int128 indexNow)
        internal view returns (int256)
    {
        OpenAgg storage a = _openAgg[marketId][isLong];
        uint256 sz = a.sumSize;
        if (sz == 0) return 0;
        RiskParams storage r = _risk[marketId];
        int256 markTerm  = int256(markUnits) * int256(sz);
        int256 entryTerm = int256(a.sumEntryW);
        // long profits when mark > entry; short when entry > mark (mirrors _settleSlice's priceDiff).
        int256 priceDiff = isLong ? (markTerm - entryTerm) : (entryTerm - markTerm);
        int256 pricePnl  = priceDiff * int256(uint256(r.notionalScale));
        int256 funding   = (int256(indexNow) * int256(sz) - a.sumCheckW)
                           * int256(uint256(r.sizeTick)) / int256(ParamCatalog.SCALE);
        return pricePnl - funding;
    }

    /// @dev The vault's MARKED-TO-MARKET value: `poolAssets` minus the net unrealized effPnl the
    /// pool owes its open positions (their profit is the pool's liability). `deposit`/`withdraw`
    /// price against this, not raw `poolAssets`, so a stale-NAV first-mover can neither extract on
    /// exit (traders net-up ⇒ mtm < poolAssets) nor mint outsized shares on entry (traders net-down
    /// ⇒ mtm > poolAssets). O(1) from the per-side aggregates.
    ///
    /// APPROXIMATION (accepted): uses UNCAPPED unrealized loss — a losing position cannot actually
    /// lose past its collateral (beyond that it is liquidatable), so mtm slightly overstates the
    /// pool's claim on deeply-underwater, not-yet-liquidated positions; `liqWidthPpm` bounds that
    /// window. It also ignores the (non-linear, un-aggregatable) winnings cut, which only
    /// understates the LPs' share — conservative.
    /// The owed-winnings `outstanding` is also subtracted: it is a SETTLED liability senior to the
    /// LPs (winners the pool couldn't fully pay yet), so LP value is `poolAssets − outstanding −
    /// net open effPnl`.
    function _mtmValue(uint256 marketId) internal view returns (uint256) {
        IH2Oracle.FeedView memory feed = _oracle.feedOf(_oracles[marketId].primaryFeedId);
        return _mtmValueAtMark(marketId, feed, feed.mark);
    }

    /// @dev `_mtmValue` priced against an EXPLICIT mark (`mark1e18`), with the funding term projected
    /// from `feed`'s last index/rate/push at that same mark reference. The normal NAV passes the
    /// primary feed's own mark; the fallback LP-pricing path passes a fallback edge price (the feed
    /// still supplies the funding seeds, since the fallback carries no funding index). `outstanding`
    /// is subtracted and the result clamped ≥ 0 in both.
    function _mtmValueAtMark(uint256 marketId, IH2Oracle.FeedView memory feed, uint256 mark1e18)
        internal view returns (uint256)
    {
        int256 base = int256(uint256(_vault[marketId].poolAssets)) - int256(_outstanding(marketId));
        if (feed.lastPushMs != 0) { // positions can only exist once the feed has been pushed
            uint64 nowMs = uint64(_microTimestamp() / 1000);
            int128 idxLong = FundingIndex.effectiveAtPctMs(
                feed.fundingIndexLong, feed.rateLong, mark1e18, feed.lastPushMs, nowMs);
            int128 idxShort = FundingIndex.effectiveAtPctMs(
                feed.fundingIndexShort, feed.rateShort, mark1e18, feed.lastPushMs, nowMs);
            uint256 markUnits = mark1e18 / _risk[marketId].priceTick;
            base -= _sideEffPnl(marketId, true, markUnits, idxLong)
                  + _sideEffPnl(marketId, false, markUnits, idxShort);
        }
        return base <= 0 ? 0 : uint256(base);
    }

    // ---- oracle staleness + fallback read (shared by H2Markets and the LP-pricing path) ----

    /// @dev Primary feed staleness on the HP clock — the fallback path's arming test. A never-
    /// published feed does NOT arm: no position can exist on it (both execution paths refuse), and
    /// arming it would let positions exist against a zero mark.
    function _primaryStale(uint256 marketId, IH2Oracle.FeedView memory feed)
        internal view returns (bool)
    {
        if (feed.lastPushMs == 0) return false;
        uint64 nowMs = uint64(_microTimestamp() / 1000);
        return nowMs - feed.lastPushMs > uint64(_oracles[marketId].primaryStaleSecs) * 1000;
    }

    /// @dev The fallback feed's price (1e18) and freshness, per the market's params. Rejects
    /// non-positive and future-stamped answers outright.
    function _fallbackRead(OracleParams storage o)
        internal view returns (uint256 price1e18, bool fresh)
    {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(o.fallbackFeed).latestRoundData();
        if (answer <= 0) revert OracleBadAnswer();
        uint256 upd = _updatedAtSecs(updatedAt);
        if (upd > block.timestamp + 60) revert OracleBadAnswer(); // future-stamped
        price1e18 = uint256(answer) * (10 ** (18 - uint256(o.fallbackDecimals)));
        fresh = block.timestamp <= upd + uint256(o.fallbackMaxAge);
    }

    /// @dev The NAV `deposit`/`withdraw` price against, plus the staleness regime (for views).
    /// Normal regime (primary FRESH): the marked-to-market value off the primary mark — unchanged.
    /// Primary-STALE regime: LPs are not time-sensitive, so rather than block them we price off the
    /// FRESH fallback at an LP-ADVERSE band edge (± `fbCloseSpreadPpm`): a depositor mints at the
    /// HIGH NAV (fewer shares), a withdrawer redeems at the LOW NAV, so transacting through a primary
    /// outage can never extract value from a mispriced NAV. Both band edges are evaluated and the
    /// adverse one chosen, so the sign of net OI need not be reasoned about. The `outstanding` senior
    /// subtraction and the ≥0 clamp live inside `_mtmValueAtMark` and apply in both regimes. Reverts
    /// `NoFreshPrice` when BOTH sources are stale (LPs wait); `claimWinnings` needs no mark and is
    /// exempt.
    function _lpNav(uint256 marketId, bool isWithdraw) internal view returns (uint256 nav, bool stale) {
        IH2Oracle.FeedView memory feed = _oracle.feedOf(_oracles[marketId].primaryFeedId);
        stale = _primaryStale(marketId, feed);
        if (!stale) return (_mtmValueAtMark(marketId, feed, feed.mark), false);
        OracleParams storage o = _oracles[marketId];
        (uint256 fb, bool fresh) = _fallbackRead(o);
        if (!fresh) revert NoFreshPrice();
        uint256 band = uint256(o.fbCloseSpreadPpm);
        uint256 lo = _mtmValueAtMark(marketId, feed, fb * (PPM - band) / PPM);
        uint256 hi = _mtmValueAtMark(marketId, feed, fb * (PPM + band) / PPM);
        nav = isWithdraw ? (lo < hi ? lo : hi) : (lo > hi ? lo : hi);
    }

    // ---- owed-winnings queue helpers (FIFO funded frontier) ----

    /// @dev Total unpaid owed on a market (senior to LPs).
    function _outstanding(uint256 marketId) internal view returns (uint256) {
        return owedTail[marketId] - owedHead[marketId];
    }

    /// @dev The pool cash a NEW winner may drain: `poolAssets` minus the senior owed reservation,
    /// floored at 0. Keeps already-enqueued owed fully funded ahead of any fresh winning draw.
    function _drainable(uint256 marketId) internal view returns (uint256) {
        uint256 pa = uint256(_vault[marketId].poolAssets);
        uint256 o  = _outstanding(marketId);
        return pa > o ? pa - o : 0;
    }

    /// @dev The cumulative owed position the pool can currently fund: everything paid, plus the
    /// liquid pool, capped at everything enqueued. An entry at `start` is funded iff this exceeds
    /// `start` — so earlier entries (lower `start`) are always covered first, regardless of who
    /// calls claim. `owedHead + poolAssets` is invariant to a claim (both move by the paid amount),
    /// so claiming never retroactively unfunds another entry.
    function _headFundable(uint256 marketId) internal view returns (uint256) {
        uint256 tail = owedTail[marketId];
        uint256 funded = owedHead[marketId] + uint256(_vault[marketId].poolAssets);
        return funded < tail ? funded : tail;
    }

    /// @dev How much of entry `id` is claimable right now = clamp(headFundable − start, 0, amount) − claimed.
    function _entryClaimable(uint256 marketId, uint256 id) internal view returns (uint256) {
        OwedEntry storage e = _owedQueue[marketId][id];
        uint256 start = uint256(e.start);
        uint256 hf    = _headFundable(marketId);
        if (hf <= start) return 0;
        uint256 fundedAmt = hf - start;
        uint256 amount = uint256(e.amount);
        if (fundedAmt > amount) fundedAmt = amount;
        uint256 claimed = uint256(e.claimed);
        return fundedAmt > claimed ? fundedAmt - claimed : 0;
    }

    /// @dev Enqueue a shortfall owed to `user`; records `start = owedTail` (so it is junior to all
    /// prior owed) and bumps the tail. Returns the entry id.
    function _enqueueOwed(uint256 marketId, address user, uint256 amount) internal returns (uint256 id) {
        id = _owedQueue[marketId].length;
        _owedQueue[marketId].push(OwedEntry({
            user: user, start: uint128(owedTail[marketId]), amount: uint128(amount), claimed: 0
        }));
        _userOwed[marketId][user].push(id);
        owedTail[marketId] += amount;
    }

    // ---- builder eligibility ----

    /// @dev Is `builder` eligible on `marketId`, per that market's frozen registry? False when
    /// the market has no registry (0) or the builder is 0. The registry is an external,
    /// market-creator-chosen contract, so its `isBuilder` is called behind a try/catch: a
    /// reverting or hostile registry must never brick order execution — it just forfeits the
    /// builder share to the vault (a `false`).
    /// @dev Is `builder` eligible on this market's registry? The registry is a caller-chosen
    /// external contract, so this must NEVER be able to brick or gas-bomb an order — any anomaly
    /// forfeits the builder share to the vault and the order still executes. A high-level
    /// try/catch is not enough (it catches neither out-of-gas nor a malformed/garbage return), so
    /// use a BOUNDED-GAS low-level staticcall with a strict decode:
    ///   - the 30k gas cap ⇒ an OOG bomb burns at most that (EIP-150 leaves the caller its gas),
    ///     and it also caps how large a returndata blob the callee can build, so a returndata bomb
    ///     cannot meaningfully inflate our gas even though the return is copied;
    ///   - `ret.length == 32` rejects a malformed/garbage or codeless (empty) return;
    ///   - decoding to uint256 and requiring `== 1` accepts only a clean boolean true (a garbage
    ///     word decodes without reverting and simply fails the `== 1` test).
    function _builderEligible(uint256 marketId, address builder) internal view returns (bool) {
        address reg = _builderRegistry[marketId];
        if (reg == address(0) || builder == address(0)) return false;
        (bool success, bytes memory ret) =
            reg.staticcall{ gas: 30000 }(abi.encodeWithSelector(IBuilderRegistry.isBuilder.selector, builder));
        return success && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    // ---- tick helpers ----

    function _toPriceUnits(uint256 input, uint256 priceTick) internal pure returns (uint128) {
        if (input == 0 || input % priceTick != 0) revert BadMark();
        uint256 pu = input / priceTick;
        if (pu >= UNITS_CAP) revert BadMark();
        return uint128(pu);
    }
    function _toSizeUnits(uint256 input, uint256 sizeTick) internal pure returns (uint128) {
        if (input == 0 || input % sizeTick != 0) revert BadSize();
        uint256 su = input / sizeTick;
        if (su >= UNITS_CAP) revert BadSize();
        return uint128(su);
    }
    function _priceOut(uint128 priceUnits, uint256 priceTick) internal pure returns (uint256) {
        return uint256(priceUnits) * priceTick;
    }
    function _sizeOut(uint128 sizeUnits, uint256 sizeTick) internal pure returns (uint256) {
        return uint256(sizeUnits) * sizeTick;
    }
    function _notional(uint128 priceUnits, uint128 sizeUnits, uint256 notionalScale)
        internal pure returns (uint256)
    {
        return uint256(priceUnits) * uint256(sizeUnits) * notionalScale;
    }
}
