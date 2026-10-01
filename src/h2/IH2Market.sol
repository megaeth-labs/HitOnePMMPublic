// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IH2Market
/// @notice External interface for the H2 exchange — ownerless, immutable, and priced
/// entirely by oracles (see IH2Oracle and ORACLE_DESIGN.md).
///
/// **The contract is the market maker.** Fills derive from the oracle mark ± the market's
/// frozen fee curves ± a capped oracle spread; funding accrues from the feed's two-sided
/// rate indices; liquidation triggers when the oracle comes within a frozen width of a
/// position's liquidation price. Nobody quotes a price a formula didn't derive, so the
/// party publishing the feed is an oracle operator, not a counterparty.
///
/// **Three execution tiers** (see ORACLE_DESIGN.md §2). Operator-attached: user-signed
/// orders ride the operator's mark commits via the oracle's pull path (`onMark`, callable
/// only by the oracle), at the freshest mark. Self-service (`executeAtMark`): anyone may
/// execute against the current primary mark while it is fresher than the ring's sentinel
/// gap, paying a staleness spread that grows with the mark's age. Fallback
/// (`executeAtFallback`): once the primary is stale, anyone may execute and liquidate
/// against the market's fallback push feed. Whenever a fresh fallback exists, a deviation
/// gate blocks any action if the two price sources disagree.
///
/// **Markets are frozen.** `createMarket` fixes every parameter forever; changing anything
/// means a new market. The per-market treasury (index lending: pooled lender capital that
/// backs the book and earns a fixed rate) is specified in TREASURY_DESIGN.md.

interface IH2Market {
    // ============================================================
    // market parameter structs (each ≤ 24 fields for tooling)
    // ============================================================

    /// @notice Fee curves and the winnings cut. Rates are PPM (1 ppm = 0.01 bps); the
    /// curve at notional N (whole USDM) is `flat + linear·N/1e6 + quad·N²/1e12` ppm —
    /// linear/quad read as "extra ppm at $1M notional".
    struct FeeParams {
        uint32 openFlatPpm;      // ≤ 100_000 (10%)
        uint64 openLinearScale;  // ≤ 1e6
        uint64 openQuadScale;    // ≤ 1e6
        uint32 closeFlatPpm;     // ≤ 100_000
        uint64 closeLinearScale; // ≤ 1e6
        uint64 closeQuadScale;   // ≤ 1e6
        uint32 cutInterceptPpm;  // winnings-cut ramp on percent return (ParamCatalog.houseCut)
        uint32 cutSlopePpm;
        uint32 maxCutPpm;        // ≤ 500_000 (50%)
        uint32 maxBuilderFeePpm; // ≤ 500_000; cap on a per-order builder's share of fees+cut
    }

    /// @notice Vol/skew → spread parameterization (see ORACLE_DESIGN.md). The operator
    /// publishes a `(vol, skew)` estimate on the feed; the contract derives the per-side,
    /// per-action spread from these frozen coefficients:
    ///   spread = volK·vol²/VOL_REF ± skewK·skew/SKEW_REF   (clamped to [0, maxSpreadPpm])
    /// where `+` is applied to the taker's BUY side (skew>0 ⇒ buyers pay more: opening a long or
    /// closing a short) and `−` to the sell side — by fill direction, not position side. Zero the
    /// close coefficients for zero close spread (the winnings rake covers closes). See
    /// `ParamCatalog.derivedSpread` for the scales (vol/skew in PPM, 10_000 = 1%).
    struct SpreadParams {
        uint32 openVolK;   // ≤ 1e9; ppm of open spread at 1% vol
        uint32 openSkewK;  // ≤ 1e9; ppm of open spread per 1% skew (asymmetry)
        uint32 closeVolK;  // ≤ 1e9; 0 ⇒ zero close spread
        uint32 closeSkewK; // ≤ 1e9
    }

    /// @notice Position and treasury risk bounds. `notionalScale` is derived (leave 0).
    struct RiskParams {
        uint128 priceTick;            // must equal the primary feed's tick
        uint128 sizeTick;
        uint128 notionalScale;        // derived = priceTick·sizeTick/usdmDenom
        uint16  minLeverage;          // [1, 10000]
        uint16  maxLeverage;
        uint32  maxPositionDuration;  // [1h, 365d]
        uint128 maxPositionNotional;  // required nonzero
        uint128 maxOIGross;           // 0 = unlimited
        uint128 maxOISkew;            // 0 = unlimited
        uint32  liqWidthPpm;          // early-trigger maintenance width (≤ 100_000):
                                      // liquidatable once equity ≤ width × notional-at-mark,
                                      // so the full knockout lands BEFORE bankruptcy
        uint64  fundingRateCapPerSec; // cap on the feed's rates at consumption (100·2⁶³ scale)
        uint32  maxSpreadPpm;         // cap on the derived (vol/skew) spread; 0 ⇒ NO derived
                                      // spread (the clamp pins every fill to 0), NOT "uncapped"
        uint32  unstakeSecs;          // share-vault withdrawal cooldown ([0, 30d]); shares keep
                                      // earning through it — pure exit friction
        uint32  staleSpreadK;         // self-service staleness-spread coefficient, ppm per
                                      // √millisecond of mark age (≈ 2σ); 0 disables
                                      // executeAtMark for this market
        uint32  minAdjustGapBlocks;   // min blocks between adjustments to one position (≥ 1);
                                      // bounds size-fee chunking + winnings-cut basis dilution
    }

    /// @notice The market's two price sources and the parameters governing failover.
    struct OracleParams {
        uint64  primaryFeedId;        // H2Oracle feed; its operator publishes this market's prices
        uint32  primaryStaleSecs;     // primary age that arms the fallback path (≤ 1 d)
        address fallbackFeed;         // AggregatorV3-shaped push feed (required)
        uint8   fallbackDecimals;
        uint32  fallbackMaxAge;       // fallback freshness the fallback path requires (≤ 1 h)
        uint32  fbOpenSpreadPpm;      // fallback open spread, against the taker (≤ 200_000)
        uint32  fbCloseSpreadPpm;     // fallback close spread, against the taker (≤ 200_000)
        uint32  fbLiqSpreadPpm;       // fallback liquidation cushion, position's favor (≤ fbCloseSpreadPpm)
        uint32  maxDeviationPpm;      // both-fresh gate: |primary − fallback| ≤ this (PPM of fallback)
    }

    // ============================================================
    // EIP-712 order + oracle-callback payloads
    // ============================================================

    /// @notice A user-signed order naming the exact `marketId` (which pins both oracles
    /// and every frozen parameter). Executed either by the feed operator attaching it to a
    /// mark commit (primary) or by anyone via the fallback path. `(channel, nonce)` are
    /// user-scoped, single-use, and cancellable.
    struct Order {
        address user;
        uint256 marketId;
        bool    isLong;
        bool    isOpen;          // true = open/increase, false = close/decrease
        uint256 size;            // 1e18 asset-wei
        uint256 leverage;        // ignored on close
        uint256 targetPrice;     // 1e18 USDM-wei
        uint256 maxSlippageBps;  // worst acceptable deviation from targetPrice
        uint64  deadline;
        uint256 channel;
        uint256 nonce;
        address builder;         // 0 = no builder; else earns `builderFeePpm` of this order's
                                 // fees+cut (must be a registered builder at execution)
        uint256 builderFeePpm;   // this order's builder share; ≤ the market's maxBuilderFeePpm
    }

    /// @notice `onMark` payload kinds. Each oracle Call carries ONE action so the oracle's
    /// per-call isolation gives per-action isolation for free.
    /// - Order:     payload = abi.encode(Order, bytes signature)
    /// - Liquidate: payload = abi.encode(uint256[] positionIds)
    enum ActionKind { Order_, Liquidate }

    // ============================================================
    // views
    // ============================================================

    struct MarketView {
        address creator;
        address token;
        uint64  primaryFeedId;
        uint256 mark;               // primary feed's last mark, 1e18
        uint64  lastPushMs;         // primary feed's HP-clock age input
        uint256 openInterestLong;   // USDM-wei notional
        uint256 openInterestShort;
    }

    struct PositionView {
        address user;
        uint256 marketId;
        bool    isLong;
        uint256 size;
        uint256 leverage;
        uint256 entryPrice;
        uint256 col;
        int128  fundingCheckpoint;
        uint64  openTime;   // resets on increase (walk-back floor) — see expiresAt
        uint64  expiresAt;  // fixed at FIRST open; increases never extend it
        uint256 notionalAtOpen;
        bool    closed;
        uint64  closeTime;
        uint256 closePrice;
        int256  realizedPnl;
        uint256 makerCutPaid;   // winnings cut taken (name kept for indexer continuity)
        uint256 payoutReceived;
    }

    /// @notice A market's share vault.
    struct VaultView {
        uint256 totalShares;
        uint256 poolAssets;     // USDM backing the shares (post-rake), settled basis
        uint256 mtmValue;       // marked-to-market vault value = poolAssets − net unrealized trader PnL
        uint256 sharePrice;     // mtmValue per share, 1e18-scaled (virtual-offset) — the NAV used to mint/redeem
        uint256 rakeOwed;       // feed operator's accrued rake, claimable
        address rakeRecipient;  // the feed operator
        uint256 rakePpm;        // the feed's frozen rake
    }

    /// @notice A user's stake in a market's vault.
    struct StakeView {
        uint256 shares;         // total shares held
        uint256 unstakeShares;  // shares in a pending unstake (0 if none)
        uint64  unlockAt;       // when the pending unstake can be withdrawn (0 if none)
    }

    // ============================================================
    // events
    // ============================================================

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        address indexed token,
        FeeParams fees,
        RiskParams risk,
        OracleParams oracles
    );

    event NonceUsed(address indexed user, uint256 indexed channel, uint256 indexed nonce);
    event NonceCancelled(address indexed user, uint256 indexed channel, uint256 indexed nonce);

    event PositionOpened(
        uint256 indexed id,
        address indexed user,
        uint256 indexed marketId,
        bool    isLong,
        uint256 size,
        uint256 entryPrice,
        uint256 collateral,
        uint64  openTime,
        int128  fundingCheckpoint
    );
    event PositionIncreased(
        uint256 indexed id,
        uint256 indexed marketId,
        uint256 addSize,
        uint256 fillPrice,
        uint256 newSize,
        uint256 newEntryPrice,
        uint256 addCollateral,
        uint256 openFee,
        int128  newFundingCheckpoint
    );
    event PositionClosed(
        uint256 indexed id,
        uint256 indexed marketId,
        uint256 closePrice,
        int256  pnl,
        int256  fundingPaid,
        uint256 makerCut,
        uint256 closeFee,
        uint256 payout
    );
    event PositionDecreased(
        uint256 indexed id,
        uint256 indexed marketId,
        uint256 closeSize,
        uint256 closePrice,
        int256  pnl,
        int256  fundingPaid,
        uint256 makerCut,
        uint256 closeFee,
        uint256 payout,
        uint256 remainingSize
    );
    event PositionLiquidated(uint256 indexed id, uint256 markAtLiq, uint16 ringStepFound, uint256 collateralWiped);
    event PositionExpired(uint256 indexed id, uint256 closePrice, uint256 payout);

    /// @notice A self-service execution against the (stale) primary mark.
    event MarkExecuted(uint256 indexed marketId, uint256 indexed positionId, uint256 mark, uint256 fillPrice, uint256 ageMs);
    /// @notice A fallback-path execution (the position events above fire as usual).
    event FallbackExecuted(uint256 indexed marketId, uint256 indexed positionId, uint256 oraclePrice, uint256 fillPrice);
    event FallbackLiquidated(uint256 indexed marketId, uint256 oraclePrice, uint256 count);

    // ---- treasury: share vault (see TREASURY_DESIGN.md) ----

    event Deposited(uint256 indexed marketId, address indexed user, uint256 assets, uint256 shares);
    /// @notice A lender started the withdrawal cooldown; the shares keep earning until withdrawn.
    event UnstakeRequested(uint256 indexed marketId, address indexed user, uint256 shares, uint64 unlockAt);
    event Withdrawn(uint256 indexed marketId, address indexed user, uint256 shares, uint256 assets);
    /// @notice The feed operator claimed the market's accrued rake.
    event RakeClaimed(uint256 indexed marketId, address indexed to, uint256 amount);

    // ---- builder codes (eligibility lives in the per-market IBuilderRegistry) ----

    /// @notice An eligible builder earned `amount` from an order's fees/cut it built.
    event BuilderFeeAccrued(
        uint256 indexed marketId, address indexed builder, uint256 indexed positionId,
        bool isOpenSide, uint256 amount
    );
    /// @notice A builder claimed its accrued fees.
    event BuilderFeesClaimed(address indexed builder, address indexed to, uint256 amount);

    // ============================================================
    // errors
    // ============================================================

    error BadMarketParams();
    error UnknownMarket();
    error NotOracle();         // onMark caller is not the H2Oracle
    error FeedMismatch();      // callback feed is not the market's primary feed

    error BadLeverage();
    error BadSize();
    error BadMark();
    error PositionExists();
    error NoPosition();
    error PositionAlreadyClosed();
    error PositionDurationNotElapsed();
    error PositionDoesNotExist();
    error PositionLiquidatable();  // increase refused while a liquidation is recorded
    error NoneLiquidated();
    error Insolvent();
    error AdjustmentTooSoon();     // an adjustment (increase/decrease/close) came within
                                   // `minAdjustGapBlocks` of the position's last one (anti
                                   // size-fee chunking / basis dilution); wait out the gap
    error IncreaseAfterExpiry();   // cannot add size to a position past its expiry

    error OrderExpired();
    error NonceAlreadyUsed();
    error SlippageExceeded();
    error BadUserSig();
    error PositionNotionalCap();
    error OIGrossCap();
    error OISkewCap();

    // oracles
    error RateCapExceeded();       // feed rate beyond the market's frozen cap, at consumption
    error DeviationGate();         // both oracles fresh and disagreeing — actions blocked
    error FallbackNotArmed();      // primary feed not stale enough
    error MarkTooStale();          // executeAtMark: primary mark older than the sentinel gap
    error SelfServiceDisabled();   // executeAtMark: market's staleSpreadK is 0
    error OracleTooOld();          // fallback feed stale (or future-stamped)
    error OracleBadAnswer();
    error PrimaryNeverPushed();    // no mark exists (expiry/settlement refuse a zero mark)

    // treasury (share vault)
    error UnbandedFeed();     // deposits require a banded primary feed (ring integrity)
    error InsufficientShares(); // unstake request exceeds shares held
    error NothingStaked();    // no pending unstake to withdraw
    error CooldownActive();   // withdraw before the unstake cooldown elapsed
    error InsufficientLiquidity(); // withdrawal's MTM value exceeds liquid poolAssets — wait for open positions to settle
    error NotFeedOperator();  // claimRake caller is not the primary feed's operator
    error ZeroAddress();
    error ZeroAmount();

    // builder codes
    error BadBuilderFee();    // order names a builder-rate above the market cap, or a rate with no builder

    // ============================================================
    // markets
    // ============================================================

    /// @notice Create a market. Permissionless; `msg.sender` is recorded as the creator
    /// (identity only — the treasury is a role-less share vault). All three param structs
    /// are validated then frozen. Structural rules beyond field bounds:
    ///  - the market's `priceTick` must equal the primary feed's tick;
    ///  - the ANTI-SANDWICH bound: `openFlatPpm + closeFlatPpm ≥ maxDeviationPpm` — the
    ///    minimum round-trip cost must exceed the worst oracle disagreement the gate
    ///    tolerates, so the treasury can never be traded as a deviation ATM;
    ///  - the coupled funding ceiling: `fundingRateCapPerSec × primaryStaleSecs ×
    ///    maxLeverage ≤ ½·PCT_SCALE` — funding during the window users cannot exit without
    ///    the operator can never eat more than half of worst-case collateral.
    function createMarket(
        address token,
        FeeParams calldata fees,
        RiskParams calldata risk,
        OracleParams calldata oracles,
        SpreadParams calldata spread,
        address builderRegistry
    ) external returns (uint256 marketId);

    function spreadParamsOf(uint256 marketId) external view returns (SpreadParams memory);

    function usdm() external view returns (IERC20);
    function oracle() external view returns (address);
    function nextMarketId() external view returns (uint256);
    function creatorOf(uint256 marketId) external view returns (address);
    function feeParamsOf(uint256 marketId) external view returns (FeeParams memory);
    function riskParamsOf(uint256 marketId) external view returns (RiskParams memory);
    function oracleParamsOf(uint256 marketId) external view returns (OracleParams memory);
    function marketOf(uint256 marketId) external view returns (MarketView memory);

    // ============================================================
    // primary path — the oracle's pull callback
    // ============================================================

    /// @notice Invoked by H2Oracle (ONLY) inside `pushAndCall`, after the mark is
    /// committed. `data = abi.encode(uint256 marketId, uint8 ActionKind, bytes payload)`.
    /// Orders route to open / increase / close from `isOpen` and the user's active
    /// position, filling at `mark ± cappedFeedSpread` with the fee curves charged
    /// explicitly and folded (with the spread) into the user's signed band. Liquidation
    /// batches walk the feed's ring against the widened (`liqWidthPpm`) threshold.
    /// All actions pass the deviation gate when the fallback is also fresh.
    function onMark(uint256 feedId, bytes calldata data) external;

    // ============================================================
    // fallback path — permissionless once the primary is stale
    // ============================================================

    function fallbackArmed(uint256 marketId) external view returns (bool);

    /// @notice Self-service execution against the current primary mark, WITHOUT the
    /// operator — the order fills at `mark ± (feeCurve + feedSpread + staleSpread(age))`,
    /// where the staleness spread grows with the mark's age (`staleSpreadK · √ageMs`).
    /// Callable by ANYONE while: the market's `staleSpreadK != 0`; the mark is fresher than
    /// the ring's sentinel gap (4.095 s); and the fallback feed is fresh AND within
    /// `maxDeviationPpm` of the mark (the freshness anchor that makes a stale-mark trade
    /// safe). This is the path that makes the operator a cost optimizer rather than a
    /// gatekeeper — a user never depends on the operator to open or close.
    function executeAtMark(Order calldata order, bytes calldata userSig) external returns (uint256 id);

    /// @notice Execute a signed order at the fallback price ± the market's fallback
    /// spreads (against the taker), fee curves charged as on the primary path. Callable by
    /// ANYONE while the primary feed is stale and the fallback is fresh.
    function executeAtFallback(Order calldata order, bytes calldata userSig) external returns (uint256 id);

    /// @notice Liquidate at the fallback price shifted by `fbLiqSpreadPpm` in each
    /// position's favor, against the widened threshold. No walk-back (the primary ring is
    /// what went stale). Callable by ANYONE under the same conditions.
    function liquidateAtFallback(uint256 marketId, uint256[] calldata positionIds) external;

    // ============================================================
    // user actions
    // ============================================================

    /// @notice Retire the caller's own unspent (channel, nonce). A cancel racing an
    /// in-flight commit reverts that order's execution — a normal outcome.
    function cancelNonce(uint256 channel, uint256 nonce) external;

    /// @notice Anyone may force-close `id` once `expiresAt` has passed; settles at the
    /// primary feed's last mark (documented: under dual oracle failure this is the exit).
    function expirePosition(uint256 id) external;

    // ============================================================
    // treasury — permissionless share vault (see TREASURY_DESIGN.md)
    // ============================================================

    /// @notice Lend USDM into the market's vault; mints shares at the current NAV. All
    /// trading P&L (after the feed's rake) flows to share price. Permissionless and
    /// immediate. Requires a banded primary feed (`UnbandedFeed`) for ring integrity.
    function deposit(uint256 marketId, uint256 assets) external returns (uint256 shares);

    /// @notice Begin the withdrawal cooldown on `shares`. They STAY in the pool and keep
    /// earning + bearing P&L until `withdraw`; the cooldown (`unstakeSecs`) is exit friction
    /// only. Re-requesting resets the timer. Reverts `InsufficientShares`.
    function requestUnstake(uint256 marketId, uint256 shares) external;

    /// @notice Withdraw a matured unstake: burns the requested shares at the CURRENT NAV and
    /// pays out. Reverts `NothingStaked` / `CooldownActive`.
    function withdraw(uint256 marketId) external returns (uint256 assets);

    /// @notice Claim the market's accrued rake. Only the primary feed's operator; `to`
    /// receives the full `rakeOwed`.
    function claimRake(uint256 marketId, address to) external;

    // ============================================================
    // builder codes
    // ============================================================

    /// @notice An order may name a builder + a fee rate ≤ the market's `maxBuilderFeePpm`; if that
    /// builder is eligible per the market's `IBuilderRegistry`, it earns that share of the order's
    /// fees and winnings cut. Eligibility CRITERIA (staking, token, amount) live in the external
    /// registry, not here — a market freezes which registry it trusts at `createMarket`. An order
    /// naming an ineligible builder simply skips the cut (the vault keeps it); it does not revert.
    ///
    /// @notice Claim the caller's accrued builder fees to `to` (USDM). Fees accrue in the market
    /// as orders fill; the registry only gated eligibility to accrue them.
    function claimBuilderFees(address to) external;

    /// @notice The caller/builder's accrued, claimable fees (USDM).
    function builderOwed(address builder) external view returns (uint256);
    /// @notice The market's frozen builder registry (0 = builder codes disabled for it).
    function builderRegistryOf(uint256 marketId) external view returns (address);

    function vaultOf(uint256 marketId) external view returns (VaultView memory);
    function stakeOf(uint256 marketId, address user) external view returns (StakeView memory);
    /// @notice The market's open notional (long + short OI) — the exposure its vault backs.
    /// View only; opens are deliberately not solvency-gated.
    function grossOpenNotional(uint256 marketId) external view returns (uint256);

    // ============================================================
    // position views
    // ============================================================

    function nextPositionId() external view returns (uint256);
    function activePositionId(address user, uint256 marketId) external view returns (uint256);
    function nonceUsed(address user, uint256 channel, uint256 nonce) external view returns (bool);
    function positions(uint256 id) external view returns (PositionView memory);
}
