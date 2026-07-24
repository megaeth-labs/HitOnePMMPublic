// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ParamCatalog }  from "../common/ParamCatalog.sol";

/// @title IHitOneMarket
/// @notice External interface for the HitOne perp venue.
///
/// **Authorisation model.** Users sign EIP-712 `Order` payloads off-chain with a target
/// price and a maximum acceptable slippage. They send signed orders to HitOne's backend.
/// HitOne's maker key submits the order on-chain, attaching the price the maker commits to
/// fill at. The contract verifies the maker's `fillPrice` falls within the user's
/// `[targetPrice ± maxSlippageBps]` band, then opens or closes the position on the user's
/// behalf. This gives the maker a final say on the exact fill price (committed at submission
/// time) while letting the user enforce their own price limit.
///
/// Each `(maker, token)` is a fully isolated sub-market: its own marks, funding, risk limits,
/// open interest and collateral pool. A user picks the exact `(token, maker)` they trade against
/// by naming `maker` in their signed order.
///
/// Roles:
///   - owner   — curates the token universe (`setToken` structural grid, `setOracle`), the
///               timelocked `halter` set, and `setWithdrawDelay`. Cannot touch maker funds.
///   - maker   — PERMISSIONLESS: any address may run a book on an owner-registered token. Pushes
///               its own marks/rates, sets its own risk (`setRiskLimits`), opens/closes/liquidates
///               its own positions, and is the counterparty to them. No registration step.
///   - funder  — per-maker treasury key (`makerFunder[maker]`), self-set by the maker; funds +
///               withdraws that maker's pool. Defaults to the maker itself when unset.
///   - halter  — emergency halt/unhalt; multiple allowed, assigned via the timelocked role queue
///               (`queueSetHalter`). ONLY halters may halt/unhalt — not makers, funders, or owner.
///
/// **Collateral model.** Users hold no internal balance. They grant USDM allowance to this
/// contract; on open/increase the required collateral is pulled from the user's wallet, and
/// on close/decrease the payout is sent back to the user's wallet. Each maker keeps its own
/// segregated internal balance (`collateral[maker][token]`) and is the counterparty to the
/// positions it opens; PnL for a position settles only against its own maker's pool.
///
/// Positions are id-indexed and retained after close. At most one active position per
/// `(user, maker, token)`.
interface IHitOneMarket {
    // ============================================================
    // events
    // ============================================================

    event MakerFunderSet(address indexed maker, address indexed funder);
    event HalterSet(address indexed halter, bool allowed);
    event ConfiguratorSet(address indexed configurator);
    event WithdrawDelaySet(uint256 delay);

    /// @notice Halter role change queued behind `roleChangeDelay()`. `kind` is always 2 (halter);
    /// `account` is the halter target and `allowed` the grant/revoke flag. (`subject` unused.)
    event RoleChangeQueued(
        uint256 indexed id, uint8 kind, address subject, address account, bool allowed, uint64 readyAt
    );
    event RoleChangeExecuted(uint256 indexed id);
    event RoleChangeCancelled(uint256 indexed id);

    /// @notice Emitted when the market is halted or the halt window is extended. `haltedUntil`
    /// is the earliest timestamp at which `unhalt` may succeed.
    event Halted(address indexed by, uint64 haltedUntil);
    event Unhalted(address indexed by);

    event TokenSet(address indexed token, ParamCatalog.Structural structural);
    event RiskLimitsSet(address indexed maker, address indexed token, ParamCatalog.Risk risk);
    event OracleSet(address indexed token, address feed, uint8 decimals, uint32 maxStale, uint16 maxDevBps);

    event MakerPoolFunded(address indexed maker, address indexed from, address indexed token, uint256 amount);

    event MakerPoolWithdrawalQueued(
        uint256 indexed id, address indexed maker, address indexed token, address to, uint256 amount, uint64 readyAt
    );
    event MakerPoolWithdrawalExecuted(uint256 indexed id);
    event MakerPoolWithdrawalCancelled(uint256 indexed id);

    /// @notice Emitted on every mark set. `microTimestamp` is MegaETH's high-precision wall-clock
    /// (µs since epoch) read from the system contract, letting off-chain consumers validate that
    /// each mark was posted at a plausible time; it falls back to `block.timestamp × 1e6` when the
    /// system contract is unavailable.
    event MarkPushed(
        address indexed maker,
        address indexed token,
        uint256 newMark,
        int256  priceDelta,
        uint16  timeDeltaMs,
        bool    isSentinel,
        uint256 microTimestamp
    );
    event FundingRateChanged(address indexed maker, address indexed token, int64 oldRate, int64 newRate, uint64 startTime);

    /// @notice Off-chain indexers can use `(channel, nonce)` to flag a user order as spent.
    event NonceUsed(address indexed user, uint256 indexed channel, uint256 indexed nonce);

    event PositionOpened(
        uint256 indexed id,
        address indexed user,
        address indexed token,
        address maker,
        bool    isLong,
        uint256 size,
        uint256 entryPrice,
        uint256 collateral,
        uint64  openTime,
        int128  fundingCheckpoint
    );

    event PositionClosed(
        uint256 indexed id,
        address indexed maker,
        uint256 closePrice,
        int256  pnl,
        int256  fundingPaid,
        uint256 makerCut,
        uint256 payout
    );

    event PositionLiquidated(
        uint256 indexed id,
        uint256 markAtLiq,
        uint16  ringStepFound,
        uint256 collateralWiped
    );

    event PositionExpired(uint256 indexed id, uint256 closePrice, uint256 payout);

    /// @notice Emitted when a position is grown via `increasePosition`. Fees/maker exposure
    /// are charged only on `addSize`; the rolled-over size keeps its original entry, so
    /// `newEntryPrice` is the size-weighted blend of the old entry and `fillPrice`.
    /// `addCollateral` is the net collateral added to the position (after `openFee`).
    event PositionIncreased(
        uint256 indexed id,
        address indexed maker,
        uint256 addSize,
        uint256 fillPrice,
        uint256 newSize,
        uint256 newEntryPrice,
        uint256 addCollateral,
        uint256 openFee,
        int128  newFundingCheckpoint
    );

    /// @notice Emitted when a position is partially closed via `closePosition` with
    /// `order.size < position size`. Settlement is pro-rata on `closeSize`; the maker cut is
    /// taken only on the slice cashed out. `remainingSize` is what stays open afterwards.
    event PositionDecreased(
        uint256 indexed id,
        address indexed maker,
        uint256 closeSize,
        uint256 closePrice,
        int256  pnl,
        int256  fundingPaid,
        uint256 makerCut,
        uint256 payout,
        uint256 remainingSize
    );

    event PausedNew(bool paused);

    // ============================================================
    // errors
    // ============================================================

    error NotFunder();
    error WrongMaker();
    error NotConfigurator();
    error ConfiguratorAlreadySet();
    error NotHalter();
    error NotPausedNewAuth();
    error MarketHalted();
    error NotHalted();
    error HaltCooldownActive();
    error RoleChangeUnknown();
    error RoleChangeNotReady();
    error BadWithdrawDelay();
    error ZeroAddress();

    error BadLeverage();
    error BadSize();
    error BadMark();

    error MarkDeltaTooLarge();
    error MarkStale();
    error MarkSameSlot();
    error MarkOutOfOracleBand();
    error OracleStale();
    error OracleBadAnswer();
    error BadOracleConfig();

    error PositionExists();
    error NoPosition();
    error PositionAlreadyClosed();
    error PositionDurationNotElapsed();
    error PositionDoesNotExist();
    error TokenMismatch();
    error NotLiquidatable();
    error NoneLiquidated();

    error UnknownToken();
    error Insolvent();

    error OrderExpired();
    error NonceAlreadyUsed();
    error SlippageExceeded();
    /// Signed order rejected: bad signature, wrong isOpen action, or (on increase/close) a
    /// side/leverage/size that doesn't match the active position.
    error BadUserSig();

    error PositionNotionalCap();
    error OIGrossCap();
    error OISkewCap();

    error PausedNewOpens();

    error WithdrawalNotReady();
    error WithdrawalUnknown();

    // ============================================================
    // constants
    // ============================================================

    function WITHDRAW_DELAY_MIN() external view returns (uint256);
    function WITHDRAW_DELAY_MAX() external view returns (uint256);
    function HALT_COOLDOWN()     external view returns (uint256);

    // ============================================================
    // EIP-712 order signed by the user
    // ============================================================

    /// @notice A user-signed order. The maker fills it with their chosen `fillPrice` at
    /// submission time. The contract enforces `|fillPrice − targetPrice| ≤ maxSlippageBps`
    /// (against targetPrice) so the user controls their worst acceptable price.
    /// `(channel, nonce)` are user-scoped and single-use.
    struct Order {
        address user;            // position holder; signer of this order
        address maker;           // exact counterparty the user chose; must equal the submitter
        address token;
        bool    isLong;
        bool    isOpen;          // true=open, false=close
        uint256 size;            // 1e18 asset-wei
        uint256 leverage;        // ignored on close
        uint256 targetPrice;     // 1e18 USDM-wei — user's intended fill price
        uint256 maxSlippageBps;  // worst acceptable deviation from targetPrice
        uint64  deadline;        // last block.timestamp this order is valid
        uint256 channel;         // user-scoped nonce lane
        uint256 nonce;           // monotonic within (user, channel) is recommended
    }

    // ============================================================
    // view structs
    // ============================================================

    /// @notice Live per-token market state.
    struct MarketView {
        uint256 mark;               // 1e18 USDM-wei
        int128  fundingIndex;
        int64   currentRatePct;     // signed fixed-point funding rate, ±1%/sec across int64
        uint64  ringHead;
        uint256 openInterestLong;   // USDM-wei notional
        uint256 openInterestShort;  // USDM-wei notional
    }

    /// @notice A position's stored fields. `realizedPnl` is the *effective* PnL (net of funding);
    /// the gross PnL / funding split is recoverable from the `PositionClosed` event. `payoutReceived`
    /// is derived: `max(0, col + realizedPnl - makerCutPaid)`. Live `liqPrice` / `fundingOwed` are
    /// NOT returned (they were dropped to fit the contract-size limit) — compute them off-chain from
    /// these fields + the maker's current mark/funding (`marketOf(maker, token)`), mirroring the
    /// on-chain `_isLiquidatable` math.
    struct PositionView {
        address user;
        address token;
        bool    isLong;
        uint256 size;
        uint256 leverage;
        uint256 entryPrice;
        uint256 col;
        int128  fundingCheckpoint;
        uint64  openTime;
        uint256 notionalAtOpen;
        bool    closed;
        uint64  closeTime;
        uint256 closePrice;
        int256  realizedPnl;
        uint256 makerCutPaid;
        uint256 payoutReceived;
    }

    // ============================================================
    // state getters
    // ============================================================

    function usdm() external view returns (IERC20);
    function makerFunder(address maker) external view returns (address);
    function isHalter(address account) external view returns (bool);
    function configurator() external view returns (address);
    function pausedNew() external view returns (bool);
    function halted() external view returns (bool);
    function haltedUntil() external view returns (uint64);
    function withdrawDelay() external view returns (uint256);
    function roleChangeDelay() external view returns (uint256);

    /// @notice Owner-curated token grid (structural). Risk is per-maker (`makerRiskOf`).
    function structuralOf(address token) external view returns (ParamCatalog.Structural memory);
    function makerRiskOf(address maker, address token) external view returns (ParamCatalog.Risk memory);
    function oracleOf(address token)
        external view returns (address feed, uint8 decimals, uint32 maxStale, uint16 maxDevBps);

    /// @notice Segregated pool balance for `account` (a maker). Each maker holds its own pool;
    /// user collateral is pulled from and paid back to wallets directly, so non-maker rows read 0.
    function collateral(address account, address token) external view returns (uint256);

    /// @notice Live state of the `(maker, token)` sub-market.
    function marketOf(address maker, address token) external view returns (MarketView memory);
    function rateRingAt(address maker, address token, uint16 idx) external view returns (int64);

    function nextPositionId() external view returns (uint256);
    function activePositionId(address user, address maker, address token) external view returns (uint256);

    function nonceUsed(address user, uint256 channel, uint256 nonce) external view returns (bool);

    function positions(uint256 id) external view returns (PositionView memory);

    // ============================================================
    // admin
    // ============================================================

    /// @notice Queue a halter grant/revoke behind `roleChangeDelay()`; `executeRoleChange` applies
    /// it after the delay, `cancelRoleChange` (owner) drops it. The halter is the only timelocked
    /// role — makers self-register and self-fund.
    function queueSetHalter(address h, bool allowed) external returns (uint256 id);
    function executeRoleChange(uint256 id) external;
    function cancelRoleChange(uint256 id) external;
    function pendingRoleChange(uint256 id)
        external view returns (uint8 kind, address subject, address account, bool allowed, uint64 readyAt, bool exists);

    /// @notice The `HitOneConfig` contract authorized to write owner params via `apply*`. Bootstrap
    /// once with `setConfigurator` (instant while unset); swap via `queueSetConfigurator` (timelocked,
    /// executed through `executeRoleChange`).
    function setConfigurator(address c) external;
    function queueSetConfigurator(address c) external returns (uint256 id);

    /// @notice A maker sets its own funder (treasury) key for its pool. While unset the maker is
    /// its own funder; once set, only the current funder may rotate it. Pass address(0) to reset.
    function setMakerFunder(address maker, address funder) external;

    /// @notice Set the maker-pool withdrawal timelock. Clamped to [WITHDRAW_DELAY_MIN,
    /// WITHDRAW_DELAY_MAX]; also sets `roleChangeDelay` (= 2×). Instant, but the MIN floor
    /// guarantees a minimum window even under an adversarial owner.
    function setWithdrawDelay(uint256 d) external;

    // ---- Owner param writes (configurator only; validation + timelock in HitOneConfig) ----
    /// @notice Write validated structural params. `priceTick == 0` deregisters.
    function applyStructural(address token, ParamCatalog.Structural calldata structural) external;
    /// @notice Write the validated oracle band (`feed == 0` disables it).
    function applyOracle(address token, address feed, uint8 decimals, uint32 maxStale, uint16 maxDevBps) external;

    /// @notice A maker sets the risk limits for its OWN book on `token` (permissionless, instant).
    function setRiskLimits(address token, ParamCatalog.Risk calldata risk) external;

    /// @notice Emergency halt. Callable ONLY by a halter (`isHalter`) — not makers, funders, or
    /// the owner. Freezes opens, increases, closes, liquidations and mark pushes. Sets a fresh
    /// `HALT_COOLDOWN` window; calling again while halted only pushes `haltedUntil` further out.
    function halt() external;
    /// @notice Lift the halt. Halter only, and only once `haltedUntil` has elapsed.
    function unhalt() external;
    function setPausedNew(bool paused) external;

    // ============================================================
    // maker pool
    // ============================================================

    /// @notice `maker`'s funder supplies collateral to that maker's segregated pool, pulling USDM
    /// from msg.sender. Callable only by `makerFunder[maker]`.
    function fundMakerPool(address maker, address token, uint256 amount) external;

    /// @notice Queue a withdrawal from `maker`'s pool. Callable only by `makerFunder[maker]`.
    /// Ready after `withdrawDelay`. `cancelWithdrawMakerPool` is likewise funder-gated (not owner).
    function queueWithdrawMakerPool(address maker, address token, uint256 amount, address to)
        external returns (uint256 id);
    function executeWithdrawMakerPool(uint256 id) external;
    function cancelWithdrawMakerPool(uint256 id) external;
    function pendingMakerPoolWithdrawal(uint256 id)
        external view returns (address maker, address token, address to, uint256 amount, uint64 readyAt, bool exists);

    // ============================================================
    // maker: mark + rate (admin push, no order)
    // ============================================================

    function setMark(address token, uint256 newMark) external;

    /// @notice Push a new mark and funding rate for `token`.
    /// @param newRate Funding rate as a signed fixed-point FRACTION per second:
    ///   real_fraction_per_sec = newRate / (100 * 2**63). The full int64 range spans ±1%/sec, so the
    ///   rate is inherently hard-capped at 1%/sec — there is no larger representable value.
    ///   E.g. 0.01%/hour ≈ (1e-4 / 3600) * 100 * 2**63 ≈ 2.56e13. Positive → longs pay shorts;
    ///   negative → shorts pay longs. The absolute USDM funding is derived at accrual time as
    ///   `fraction * mark`, so the effective rate tracks the mark automatically — the maker does
    ///   NOT rescale it when the price moves (unlike a raw price-denominated rate).
    function setMarkAndRate(address token, uint256 newMark, int64 newRate) external;

    // ============================================================
    // maker: submit user orders
    // ============================================================

    /// @notice Open a position on behalf of `order.user`. Caller must be a whitelisted maker.
    /// The maker commits to `fillPrice` at submission time; the contract enforces
    /// `|fillPrice − order.targetPrice| × 10000 ≤ order.targetPrice × order.maxSlippageBps`.
    function openPosition(
        Order calldata order,
        uint256 fillPrice,
        bytes calldata userSig
    ) external returns (uint256 id);

    /// @notice Increase `order.user`'s existing position on `order.token` by `order.size`,
    /// committing more collateral at the same leverage. The open fee and maker exposure are
    /// charged only on the added size; the rolled-over size keeps its original entry price and
    /// funding (no realized PnL, no maker cut). `order.isOpen` must be true, and the order's
    /// `isLong`/`leverage` must match the existing position. Returns the (unchanged) position id.
    /// Note: sizing up resets the position's `openTime`, which restarts both the liquidation
    /// walk-back floor and the max-duration expiry clock.
    function increasePosition(
        Order calldata order,
        uint256 fillPrice,
        bytes calldata userSig
    ) external returns (uint256 id);

    /// @notice Close `order.user`'s active position on `order.token` at `fillPrice`. Subject
    /// to the same slippage band as opens. `order.size` may be less than the active position's
    /// size for a partial (size-down) close, settling pro-rata and leaving the remainder open;
    /// it must not exceed the position size. If a ring walk-back finds the position would have
    /// been liquidatable, the close wipes the entire position instead of paying out.
    function closePosition(
        Order calldata order,
        uint256 fillPrice,
        bytes calldata userSig
    ) external;

    /// @notice Anyone may force-close `id` after `maxPositionDuration` has elapsed.
    function expirePosition(uint256 id) external;

    // ============================================================
    // maker: liquidation
    // ============================================================

    /// @notice Liquidate `positionIds` on `token`. If `newMark` is non-zero it is first pushed
    /// as the current mark (identical to `setMark`, including the oracle-band check), so a maker
    /// can post a price and liquidate against it in a single transaction; the common case is
    /// liquidating at that just-posted mark. Pass `0` to liquidate against the existing mark.
    function liquidate(address token, uint256 newMark, uint256[] calldata positionIds) external;

}
