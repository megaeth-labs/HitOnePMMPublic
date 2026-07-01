// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata }    from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable }          from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 }            from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA }             from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { IHitOneMarket }     from "./IHitOneMarket.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";
import { IAggregatorV3 }     from "../common/IAggregatorV3.sol";
import { MarkRing }          from "../common/MarkRing.sol";
import { FundingIndex }      from "../common/FundingIndex.sol";

/// @title HitOneMarket
/// @notice User-signed-order + maker-submitted perp venue.
contract HitOneMarket is IHitOneMarket, Ownable, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    address public constant override MAKER_POOL                = address(0);
    uint256 public constant override MAKER_POOL_WITHDRAW_DELAY = 48 hours;

    uint256 internal constant MAX_FUNDING_RATE_ABS          = 1e15;
    uint256 internal constant DEFAULT_MAX_POSITION_NOTIONAL = 200_000e18;

    uint256 internal constant UNITS_CAP = 1 << 96;

    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address user,address token,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce)"
    );

    IERC20 public immutable override usdm;
    uint256 internal immutable _usdmDenom;
    address public override pauser;
    bool    public override pausedNew;

    mapping(address => bool) public override isMaker;

    mapping(address => ParamCatalog.TokenParams) internal _params;

    struct OracleConfig {
        address feed;
        uint8   decimals;
        uint32  maxStale;
    }
    mapping(address => OracleConfig) internal _oracleConfig;

    /// @notice Packed to 6 slots. Trailing fields are zero until the position closes.
    /// `realizedPnl` here is the EFFECTIVE PnL (= gross pnl − fundingPaid). The split
    /// is recoverable from the `PositionClosed` event; `payoutReceived` is also derivable:
    /// `payout = max(0, col + realizedPnl - makerCutPaid)`.
    struct Position {
        // Slot 0
        address user;             // 20
        uint64  openTime;         // 8
        uint16  leverage;         // 2 (max 10_000x)
        bool    isLong;           // 1
        bool    closed;           // 1
        // Slot 1
        address token;            // 20
        uint64  closeTime;        // 8
        // Slot 2
        uint128 entryPrice;       // priceUnits
        uint128 size;             // sizeUnits
        // Slot 3
        uint128 closePrice;       // priceUnits
        uint128 col;              // USDM-wei (bounded by maxPositionNotional)
        // Slot 4
        int128  fundingCheckpoint;
        int128  realizedPnl;      // effPnl = pnl − funding
        // Slot 5
        uint128 notionalAtOpen;   // USDM-wei (snapshot, immutable)
        uint128 makerCutPaid;     // USDM-wei (snapshot, immutable)
    }
    mapping(uint256 => Position) internal _positions;
    uint256 public override nextPositionId;

    mapping(address => mapping(address => uint256)) public override activePositionId;
    /// @notice usedNonce[user][channel][nonce].
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public override nonceUsed;

    mapping(address => mapping(address => uint256)) public override collateral;
    mapping(address => uint256) internal openInterestLong;
    mapping(address => uint256) internal openInterestShort;

    struct MarkState {
        uint128 currentMark;
        uint64  lastPushAt;
        uint64  ringHead;
        int128  fundingIndex;
        int64   currentRate;
    }
    mapping(address => MarkState) internal _markState;
    mapping(address => uint256[25]) internal _markRing;
    mapping(address => uint256[50]) internal _rateRing;

    struct PendingWithdrawal {
        address token;
        address to;
        uint128 amount;
        uint64  readyAt;
        bool    exists;
    }
    mapping(uint256 => PendingWithdrawal) internal _pendingWithdrawals;
    uint256 internal _nextWithdrawalId;

    modifier onlyMaker()         { if (!isMaker[msg.sender])     revert NotMaker();     _; }
    modifier onlyOwnerOrPauser() {
        if (msg.sender != owner() && msg.sender != pauser) revert NotOwnerOrPauser();
        _;
    }
    modifier whenNotPausedNew() {
        if (pausedNew) revert PausedNewOpens();
        _;
    }

    constructor(address owner_, address maker_, address usdm_)
        Ownable(owner_)
        EIP712("HitOneMarket", "1")
    {
        if (usdm_ == address(0) || maker_ == address(0)) revert ZeroAddress();
        usdm = IERC20(usdm_);
        _usdmDenom = 10 ** uint256(IERC20Metadata(usdm_).decimals());
        isMaker[maker_] = true;
        emit MakerSet(maker_, true);
    }

    // ---- Admin ----

    function setMaker(address m, bool allowed) external override onlyOwner {
        if (m == address(0)) revert ZeroAddress();
        isMaker[m] = allowed; emit MakerSet(m, allowed);
    }
    function renounceMaker() external override {
        if (!isMaker[msg.sender]) revert NotMaker();
        isMaker[msg.sender] = false; emit MakerSet(msg.sender, false);
    }
    function setPauser(address p) external override onlyOwner {
        pauser = p; emit PauserSet(p);
    }

    function setToken(address token, ParamCatalog.TokenParams calldata p) external override onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (p.structural.priceTick == 0) {
            delete _params[token];
            ParamCatalog.Structural memory empty;
            emit TokenSet(token, empty);
            return;
        }
        ParamCatalog.Structural memory s = p.structural;
        ParamCatalog.validateAndDeriveStructural(s, _usdmDenom);
        ParamCatalog.Risk memory risk = p.risk;
        if (risk.maxPositionNotional == 0) risk.maxPositionNotional = DEFAULT_MAX_POSITION_NOTIONAL;
        if (risk.maxOIGross == 0)          risk.maxOIGross          = type(uint256).max;
        if (risk.maxOISkew == 0)           risk.maxOISkew           = type(uint256).max;
        if (risk.maxDevBps == 0)           risk.maxDevBps           = 3;
        if (risk.linearScale == 0)         risk.linearScale         = type(uint256).max;
        if (risk.quadScale == 0)           risk.quadScale           = type(uint256).max;
        ParamCatalog.validateRisk(risk);
        _params[token].structural = s;
        _params[token].risk       = risk;
        emit TokenSet(token, s);
        emit RiskLimitsSet(token, risk);
    }

    function setRiskLimits(address token, ParamCatalog.Risk calldata risk) external override onlyMaker {
        ParamCatalog.TokenParams storage cfg = _params[token];
        if (cfg.structural.priceTick == 0) revert UnknownToken();
        ParamCatalog.validateRisk(risk);
        cfg.risk = risk;
        emit RiskLimitsSet(token, risk);
    }

    function setOracle(address token, address feed, uint8 decimals_, uint32 maxStale) external override onlyOwner {
        if (_params[token].structural.priceTick == 0) revert UnknownToken();
        if (feed != address(0) && (decimals_ > 18 || maxStale == 0)) revert BadOracleConfig();
        _oracleConfig[token] = OracleConfig({ feed: feed, decimals: decimals_, maxStale: maxStale });
        emit OracleSet(token, feed, decimals_, maxStale);
    }

    function pause()   external override onlyOwnerOrPauser { _pause(); }
    function unpause() external override onlyOwner         { _unpause(); }
    function setPausedNew(bool paused_) external override {
        if (!isMaker[msg.sender] && msg.sender != pauser && msg.sender != owner()) revert NotOwnerOrPauser();
        pausedNew = paused_;
        emit PausedNew(paused_);
    }

    // ---- Collateral ----

    function fundMakerPool(address token, uint256 amount) external override onlyMaker nonReentrant {
        usdm.safeTransferFrom(msg.sender, address(this), amount);
        collateral[MAKER_POOL][token] += amount;
        emit MakerPoolFunded(msg.sender, token, amount);
    }
    function queueWithdrawMakerPool(address token, uint256 amount, address to)
        external override onlyMaker returns (uint256 id)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount > collateral[MAKER_POOL][token]) revert Insolvent();
        if (amount > type(uint128).max) revert BadSize();
        id = ++_nextWithdrawalId;
        uint64 readyAt = uint64(block.timestamp + MAKER_POOL_WITHDRAW_DELAY);
        _pendingWithdrawals[id] = PendingWithdrawal({
            token: token, to: to, amount: uint128(amount), readyAt: readyAt, exists: true
        });
        emit MakerPoolWithdrawalQueued(id, token, to, amount, readyAt);
    }
    function executeWithdrawMakerPool(uint256 id) external override nonReentrant {
        PendingWithdrawal memory w = _pendingWithdrawals[id];
        if (!w.exists)                   revert WithdrawalUnknown();
        if (block.timestamp < w.readyAt) revert WithdrawalNotReady();
        delete _pendingWithdrawals[id];
        uint256 bal = collateral[MAKER_POOL][w.token];
        if (w.amount > bal) revert Insolvent();
        unchecked { collateral[MAKER_POOL][w.token] = bal - w.amount; }
        usdm.safeTransfer(w.to, w.amount);
        emit MakerPoolWithdrawalExecuted(id);
    }
    function cancelWithdrawMakerPool(uint256 id) external override onlyOwner {
        if (!_pendingWithdrawals[id].exists) revert WithdrawalUnknown();
        delete _pendingWithdrawals[id];
        emit MakerPoolWithdrawalCancelled(id);
    }
    function pendingMakerPoolWithdrawal(uint256 id)
        external view override returns (address token, address to, uint256 amount, uint64 readyAt, bool exists)
    {
        PendingWithdrawal memory w = _pendingWithdrawals[id];
        return (w.token, w.to, uint256(w.amount), w.readyAt, w.exists);
    }

    // ---- Tick helpers ----

    function _toPriceUnits(uint256 input, uint256 priceTick) internal pure returns (uint128) {
        if (input == 0 || input % priceTick != 0) revert BadMark();
        uint256 pu = input / priceTick;
        if (pu > UNITS_CAP) revert BadMark();
        return uint128(pu);
    }
    function _toSizeUnits(uint256 input, uint256 sizeTick) internal pure returns (uint128) {
        if (input == 0 || input % sizeTick != 0) revert BadSize();
        uint256 su = input / sizeTick;
        if (su > UNITS_CAP) revert BadSize();
        return uint128(su);
    }
    function _priceOut(uint128 priceUnits, uint256 priceTick) internal pure returns (uint256) {
        return uint256(priceUnits) * priceTick;
    }
    function _sizeOut(uint128 sizeUnits, uint256 sizeTick) internal pure returns (uint256) {
        return uint256(sizeUnits) * sizeTick;
    }
    function _notional(uint128 priceUnits, uint128 sizeUnits, uint256 notionalScale) internal pure returns (uint256) {
        return uint256(priceUnits) * uint256(sizeUnits) * notionalScale;
    }

    // ---- Mark + funding (admin) ----

    function setMark(address token, uint256 newMark) external override onlyMaker whenNotPaused {
        _pushMark(token, newMark, _markState[token].currentRate, false);
    }
    function setMarkAndRate(address token, uint256 newMark, int64 newRate) external override onlyMaker whenNotPaused {
        if (uint256(int256(newRate < 0 ? -newRate : newRate)) > MAX_FUNDING_RATE_ABS)
            revert FundingRateOutOfBounds();
        _pushMark(token, newMark, newRate, true);
    }

    function _pushMark(address token, uint256 newMark_1e18, int64 nextRate, bool isRateChange) internal {
        ParamCatalog.TokenParams storage cfg = _params[token];
        if (cfg.structural.priceTick == 0) revert UnknownToken();
        uint128 newMarkUnits = _toPriceUnits(newMark_1e18, cfg.structural.priceTick);

        _checkOracleBand(token, newMark_1e18, cfg.risk.maxDevBps);

        MarkState storage st = _markState[token];
        if (st.lastPushAt == 0) {
            st.currentMark = newMarkUnits;
            st.lastPushAt  = uint64(block.timestamp);
            st.currentRate = nextRate;
            emit MarkPushed(token, newMark_1e18, 0, 0, false);
            if (isRateChange) emit FundingRateChanged(token, 0, nextRate, uint64(block.timestamp));
            return;
        }

        uint64 elapsed = uint64(block.timestamp) - st.lastPushAt;
        if (elapsed == 0) revert MarkSameSlot();

        int64 oldRate = st.currentRate;
        st.fundingIndex = FundingIndex.effectiveAt(st.fundingIndex, oldRate, st.lastPushAt, uint64(block.timestamp));

        int256 priceDelta;
        unchecked {
            priceDelta = int256(uint256(newMarkUnits)) - int256(uint256(st.currentMark));
        }

        uint64 head = st.ringHead;
        uint256 elapsedUnits = uint256(elapsed) * 1000 / MarkRing.GAP_UNIT_MS;
        bool sentinel = elapsedUnits > MarkRing.GAP_MAX_UNITS;

        uint32 markEntry;
        if (sentinel) {
            markEntry = MarkRing.sentinelEntry();
            emit MarkPushed(token, newMark_1e18, priceDelta, 0, true);
        } else {
            markEntry = MarkRing.packEntry(priceDelta, elapsedUnits);
            emit MarkPushed(token, newMark_1e18, priceDelta, uint16(elapsedUnits), false);
        }
        MarkRing.writeMarkEntry(_markRing[token], head, markEntry);
        MarkRing.writeRateEntry(_rateRing[token], head, oldRate);

        st.ringHead    = head + 1;
        st.currentMark = newMarkUnits;
        st.lastPushAt  = uint64(block.timestamp);

        if (isRateChange) {
            st.currentRate = nextRate;
            emit FundingRateChanged(token, oldRate, nextRate, uint64(block.timestamp));
        }
    }

    function _checkOracleBand(address token, uint256 newMark_1e18, uint256 maxDevBps) internal view {
        OracleConfig storage oc = _oracleConfig[token];
        address feed = oc.feed;
        if (feed == address(0)) return;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0)                                           revert OracleBadAnswer();
        if (block.timestamp > updatedAt + uint256(oc.maxStale))    revert OracleStale();
        uint256 oraclePx = uint256(answer) * (10 ** (18 - uint256(oc.decimals)));
        uint256 diff = newMark_1e18 > oraclePx ? newMark_1e18 - oraclePx : oraclePx - newMark_1e18;
        if (diff * ParamCatalog.BPS_DENOM > maxDevBps * oraclePx) revert MarkOutOfOracleBand();
    }

    // ---- Order verification ----

    function _orderDigest(Order calldata o) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.user, o.token, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce
        ));
        return _hashTypedDataV4(sh);
    }

    /// @dev Verify sig + consume nonce. Returns (no value).
    function _verifyAndConsumeOrder(Order calldata o, bytes calldata sig) internal {
        if (block.timestamp > o.deadline) revert OrderExpired();
        if (nonceUsed[o.user][o.channel][o.nonce]) revert NonceAlreadyUsed();
        address signer = ECDSA.recover(_orderDigest(o), sig);
        if (signer != o.user) revert BadUserSig();
        nonceUsed[o.user][o.channel][o.nonce] = true;
        emit NonceUsed(o.user, o.channel, o.nonce);
    }

    /// @dev Enforce maker's fillPrice is within user's [targetPrice ± maxSlippageBps] band.
    function _checkSlippageBand(uint256 fillPrice, uint256 targetPrice, uint256 maxSlippageBps) internal pure {
        uint256 diff = fillPrice > targetPrice ? fillPrice - targetPrice : targetPrice - fillPrice;
        if (diff * ParamCatalog.BPS_DENOM > targetPrice * maxSlippageBps) revert SlippageExceeded();
    }

    // ---- Open ----

    function openPosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override onlyMaker nonReentrant whenNotPaused whenNotPausedNew returns (uint256 id)
    {
        if (!order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);
        id = _openPosition(order, fillPrice);
    }

    function _openPosition(Order calldata order, uint256 fillPrice_1e18) internal returns (uint256 id) {
        ParamCatalog.TokenParams storage cfg = _params[order.token];
        if (cfg.structural.priceTick == 0) revert UnknownToken();
        if (order.size == 0 || order.leverage == 0) revert BadSize();
        if (activePositionId[order.user][order.token] != 0) revert PositionExists();

        uint128 fillPriceUnits = _toPriceUnits(fillPrice_1e18, cfg.structural.priceTick);
        uint128 sizeUnits      = _toSizeUnits(order.size, cfg.structural.sizeTick);

        uint256 markNotional = _notional(fillPriceUnits, sizeUnits, cfg.structural.notionalScale);
        uint256 collateral_  = markNotional / order.leverage;
        if (collateral_ == 0) revert BadSize();

        if (order.leverage < cfg.structural.minLeverage || order.leverage > cfg.structural.maxLeverage) revert BadLeverage();
        if (markNotional > cfg.risk.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[order.token];
        uint256 newShort = openInterestShort[order.token];
        if (order.isLong) newLong  += markNotional;
        else              newShort += markNotional;
        {
            uint256 gross = newLong + newShort;
            uint256 skew  = newLong > newShort ? newLong - newShort : newShort - newLong;
            if (gross > cfg.risk.maxOIGross) revert OIGrossCap();
            if (skew  > cfg.risk.maxOISkew)  revert OISkewCap();
        }

        uint256 fee = (markNotional * cfg.risk.openFeeBps) / ParamCatalog.BPS_DENOM;
        uint256 collAfterFee = collateral_;
        if (fee > 0) {
            if (collAfterFee <= fee) revert Insolvent();
            unchecked { collAfterFee -= fee; }
        }

        usdm.safeTransferFrom(order.user, address(this), collateral_);
        if (fee > 0) collateral[MAKER_POOL][order.token] += fee;

        _pushMark(order.token, fillPrice_1e18, _markState[order.token].currentRate, false);

        MarkState storage st = _markState[order.token];
        int128 fundingNow = FundingIndex.effectiveAt(
            st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp)
        );

        id = ++nextPositionId;
        if (order.leverage > type(uint16).max) revert BadLeverage();
        if (collAfterFee > type(uint128).max) revert BadSize();
        if (markNotional > type(uint128).max) revert BadSize();
        _positions[id] = Position({
            user:              order.user,
            openTime:          uint64(block.timestamp),
            leverage:          uint16(order.leverage),
            isLong:            order.isLong,
            closed:            false,
            token:             order.token,
            closeTime:         0,
            entryPrice:        fillPriceUnits,
            size:              sizeUnits,
            closePrice:        0,
            col:               uint128(collAfterFee),
            fundingCheckpoint: fundingNow,
            realizedPnl:       0,
            notionalAtOpen:    uint128(markNotional),
            makerCutPaid:      0
        });
        activePositionId[order.user][order.token] = id;
        openInterestLong[order.token]  = newLong;
        openInterestShort[order.token] = newShort;

        emit PositionOpened(
            id, order.user, order.token, msg.sender, order.isLong, order.size,
            fillPrice_1e18, collAfterFee, uint64(block.timestamp), fundingNow
        );
    }

    // ---- Increase (size up) ----

    function increasePosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override onlyMaker nonReentrant whenNotPaused whenNotPausedNew returns (uint256 id)
    {
        if (!order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);
        id = _increasePosition(order, fillPrice);
    }

    function _increasePosition(Order calldata order, uint256 fillPrice_1e18) internal returns (uint256 id) {
        ParamCatalog.TokenParams storage cfg = _params[order.token];
        if (cfg.structural.priceTick == 0) revert UnknownToken();
        if (order.size == 0 || order.leverage == 0) revert BadSize();

        id = activePositionId[order.user][order.token];
        if (id == 0) revert NoPosition();
        Position storage p = _positions[id];
        if (order.isLong   != p.isLong)   revert BadUserSig();
        if (order.leverage != p.leverage) revert BadUserSig();

        uint128 fillPriceUnits = _toPriceUnits(fillPrice_1e18, cfg.structural.priceTick);
        uint128 addSizeUnits   = _toSizeUnits(order.size, cfg.structural.sizeTick);

        uint256 addNotional   = _notional(fillPriceUnits, addSizeUnits, cfg.structural.notionalScale);
        uint256 addCollateral = addNotional / order.leverage;
        if (addCollateral == 0) revert BadSize();

        uint256 totalNotional = uint256(p.notionalAtOpen) + addNotional;
        if (totalNotional > cfg.risk.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[order.token];
        uint256 newShort = openInterestShort[order.token];
        if (order.isLong) newLong += addNotional; else newShort += addNotional;
        {
            uint256 gross = newLong + newShort;
            uint256 skew  = newLong > newShort ? newLong - newShort : newShort - newLong;
            if (gross > cfg.risk.maxOIGross) revert OIGrossCap();
            if (skew  > cfg.risk.maxOISkew)  revert OISkewCap();
        }

        // open fee charged only on the added size
        uint256 fee = (addNotional * cfg.risk.openFeeBps) / ParamCatalog.BPS_DENOM;
        uint256 addColAfterFee = addCollateral;
        if (fee > 0) {
            if (addColAfterFee <= fee) revert Insolvent();
            unchecked { addColAfterFee -= fee; }
        }

        usdm.safeTransferFrom(order.user, address(this), addCollateral);
        if (fee > 0) collateral[MAKER_POOL][order.token] += fee;

        _pushMark(order.token, fillPrice_1e18, _markState[order.token].currentRate, false);
        MarkState storage st = _markState[order.token];
        int128 fundingNow = FundingIndex.effectiveAt(
            st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp)
        );

        // Size-weighted blends preserve the old size's unrealized PnL and accrued funding
        // exactly, while the added size enters at fillPrice / current funding.
        uint256 oldSize = uint256(p.size);
        uint256 newSize = oldSize + uint256(addSizeUnits);
        if (newSize > UNITS_CAP) revert BadSize();
        uint256 newEntry = (uint256(p.entryPrice) * oldSize + uint256(fillPriceUnits) * uint256(addSizeUnits)) / newSize;
        int256  newCheckpoint =
            (int256(p.fundingCheckpoint) * int256(oldSize) + int256(fundingNow) * int256(uint256(addSizeUnits)))
            / int256(newSize);

        uint256 newCol = uint256(p.col) + addColAfterFee;
        if (newCol > type(uint128).max)        revert BadSize();
        if (totalNotional > type(uint128).max) revert BadSize();

        p.entryPrice        = uint128(newEntry);
        p.size              = uint128(newSize);
        p.col               = uint128(newCol);
        p.fundingCheckpoint = int128(newCheckpoint);
        p.notionalAtOpen    = uint128(totalNotional);
        // The blended entry only becomes valid now, so the liquidation walk-back must not
        // look at marks before this point (they applied to the smaller, lower-entry position).
        // Resetting openTime moves that floor; it also restarts the max-duration expiry clock.
        p.openTime          = uint64(block.timestamp);

        openInterestLong[order.token]  = newLong;
        openInterestShort[order.token] = newShort;

        emit PositionIncreased(
            id, msg.sender, order.size, fillPrice_1e18,
            _sizeOut(uint128(newSize), cfg.structural.sizeTick),
            _priceOut(uint128(newEntry), cfg.structural.priceTick),
            addColAfterFee, fee, int128(newCheckpoint)
        );
    }

    // ---- Close ----

    function closePosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override onlyMaker nonReentrant whenNotPaused
    {
        if (order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);

        ParamCatalog.TokenParams storage cfg = _params[order.token];
        uint256 id = activePositionId[order.user][order.token];
        if (id == 0) revert NoPosition();

        Position storage p = _positions[id];
        // Order's size is the portion to close; it must not exceed the position.
        uint128 closeSizeUnits = _toSizeUnits(order.size, cfg.structural.sizeTick);
        if (closeSizeUnits > p.size) revert BadUserSig();

        _pushMark(order.token, fillPrice, _markState[order.token].currentRate, false);

        (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(order.token, id);
        if (liqFound) {
            _wipePosition(id, markAtLiqUnits, ringStep);
            return;
        }

        uint128 fillPriceUnits = _toPriceUnits(fillPrice, cfg.structural.priceTick);
        if (closeSizeUnits == p.size) {
            _settleClose(id, fillPriceUnits);
        } else {
            _settleDecrease(id, closeSizeUnits, fillPriceUnits);
        }
    }

    function expirePosition(uint256 id) external override nonReentrant {
        Position storage p = _positions[id];
        if (p.user == address(0)) revert PositionDoesNotExist();
        if (p.closed) revert PositionAlreadyClosed();
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        if (block.timestamp < p.openTime + cfg.structural.maxPositionDuration) revert PositionDurationNotElapsed();
        MarkState storage st = _markState[p.token];
        uint256 payout_ = _settleClose(id, st.currentMark);
        uint256 closePrice_1e18 = _priceOut(st.currentMark, cfg.structural.priceTick);
        emit PositionExpired(id, closePrice_1e18, payout_);
    }

    function _settleClose(uint256 id, uint128 closePriceUnits) internal returns (uint256) {
        Position storage p = _positions[id];
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        MarkState storage st = _markState[p.token];

        int128 fundingNow = FundingIndex.effectiveAt(
            st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp)
        );

        (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut) =
            _settle(p, closePriceUnits, fundingNow, cfg.structural);

        _applyMakerPoolDelta(p.token, p.col, pnl, fundingPaid, makerCut);
        _decreaseOI(p.token, p.isLong, uint256(p.notionalAtOpen));

        int256 effPnl = pnl - fundingPaid;
        p.closed       = true;
        p.closeTime    = uint64(block.timestamp);
        p.closePrice   = closePriceUnits;
        // store effPnl (net of funding). Fits int128 because magnitudes are bounded by
        // notional (which fits uint128).
        p.realizedPnl  = int128(effPnl);
        p.makerCutPaid = uint128(makerCut);
        activePositionId[p.user][p.token] = 0;

        address user = p.user;
        uint256 closePrice_1e18 = _priceOut(closePriceUnits, cfg.structural.priceTick);
        emit PositionClosed(id, msg.sender, closePrice_1e18, pnl, fundingPaid, makerCut, payout);
        if (payout > 0) usdm.safeTransfer(user, payout);
        return payout;
    }

    /// @dev Partial (size-down) close: settle a pro-rata slice and leave the remainder open.
    function _settleDecrease(uint256 id, uint128 closeSizeUnits, uint128 closePriceUnits)
        internal
    {
        Position storage p = _positions[id];
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        MarkState storage st = _markState[p.token];

        int128 fundingNow = FundingIndex.effectiveAt(
            st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp)
        );

        uint256 colPortion = uint256(p.col) * closeSizeUnits / p.size;

        (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut) =
            _settleSlice(p, closeSizeUnits, colPortion, closePriceUnits, fundingNow, cfg.structural);

        _applyMakerPoolDelta(p.token, colPortion, pnl, fundingPaid, makerCut);

        uint256 notionalPortion = uint256(p.notionalAtOpen) * closeSizeUnits / p.size;
        _decreaseOI(p.token, p.isLong, notionalPortion);

        // shrink the position; entry, funding checkpoint and leverage are unchanged
        p.size           = p.size - closeSizeUnits;
        p.col            = uint128(uint256(p.col) - colPortion);
        p.notionalAtOpen = uint128(uint256(p.notionalAtOpen) - notionalPortion);

        address user = p.user;
        uint256 closePrice_1e18 = _priceOut(closePriceUnits, cfg.structural.priceTick);
        emit PositionDecreased(
            id, msg.sender, _sizeOut(closeSizeUnits, cfg.structural.sizeTick),
            closePrice_1e18, pnl, fundingPaid, makerCut, payout,
            _sizeOut(p.size, cfg.structural.sizeTick)
        );
        if (payout > 0) usdm.safeTransfer(user, payout);
    }

    function _wipePosition(uint256 id, uint128 markAtLiqUnits, uint16 ringStep) internal {
        Position storage p = _positions[id];
        uint256 wiped = uint256(p.col);
        _decreaseOI(p.token, p.isLong, uint256(p.notionalAtOpen));
        collateral[MAKER_POOL][p.token] += wiped;
        p.closed       = true;
        p.closeTime    = uint64(block.timestamp);
        p.closePrice   = markAtLiqUnits;
        p.realizedPnl  = -int128(int256(wiped));
        activePositionId[p.user][p.token] = 0;
        uint256 mark_1e18 = _priceOut(markAtLiqUnits, _params[p.token].structural.priceTick);
        emit PositionLiquidated(id, mark_1e18, ringStep, wiped);
    }

    function _applyMakerPoolDelta(address token, uint256 posCol, int256 pnl, int256 fundingPaid, uint256 makerCut) internal {
        int256 effPnl = pnl - fundingPaid;
        uint256 makerPoolBal = collateral[MAKER_POOL][token];
        if (effPnl > 0) {
            uint256 win = uint256(effPnl);
            if (makerPoolBal < win) revert Insolvent();
            unchecked { collateral[MAKER_POOL][token] = makerPoolBal - win + makerCut; }
        } else {
            uint256 loss = uint256(-effPnl);
            if (loss > posCol) loss = posCol;
            collateral[MAKER_POOL][token] += loss;
        }
    }

    function _decreaseOI(address token, bool isLong, uint256 notionalAtOpen) internal {
        if (isLong) {
            uint256 oi = openInterestLong[token];
            openInterestLong[token] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        } else {
            uint256 oi = openInterestShort[token];
            openInterestShort[token] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        }
    }

    function _settle(
        Position storage p,
        uint128 fillPriceUnits,
        int128 fundingNow,
        ParamCatalog.Structural storage s
    ) internal view returns (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut)
    {
        return _settleSlice(p, p.size, uint256(p.col), fillPriceUnits, fundingNow, s);
    }

    /// @dev Settle PnL + funding for an arbitrary `sizeUnits` slice carrying `col` collateral.
    /// With `sizeUnits == p.size` and `col == p.col` this is a full close.
    function _settleSlice(
        Position storage p,
        uint128 sizeUnits,
        uint256 col,
        uint128 fillPriceUnits,
        int128 fundingNow,
        ParamCatalog.Structural storage s
    ) internal view returns (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut)
    {
        int256 priceDiff = int256(uint256(fillPriceUnits)) - int256(uint256(p.entryPrice));
        if (!p.isLong) priceDiff = -priceDiff;
        pnl = priceDiff * int256(uint256(sizeUnits)) * int256(s.notionalScale);

        int256 fundingDelta = int256(fundingNow) - int256(p.fundingCheckpoint);
        if (!p.isLong) fundingDelta = -fundingDelta;
        fundingPaid = (fundingDelta * int256(uint256(sizeUnits) * s.sizeTick)) / int256(ParamCatalog.SCALE);

        int256 effPnl = pnl - fundingPaid;
        if (effPnl > 0) {
            makerCut = ParamCatalog.houseCut(
                uint256(effPnl), s.cutIntercept, s.cutSlopeBps, s.maxCutBps, _usdmDenom
            );
            payout = col + uint256(effPnl) - makerCut;
        } else {
            uint256 loss = uint256(-effPnl);
            payout = loss >= col ? 0 : col - loss;
        }
    }

    // ---- Liquidate ----

    function liquidate(address token, uint256[] calldata positionIds)
        external override onlyMaker nonReentrant whenNotPaused
    {
        uint256 wipedCount = 0;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 id = positionIds[i];
            Position storage p = _positions[id];
            if (p.user == address(0) || p.closed || p.token != token) continue;
            (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(token, id);
            if (!liqFound) continue;
            _wipePosition(id, markAtLiqUnits, ringStep);
            wipedCount++;
        }
        if (wipedCount == 0) revert NoneLiquidated();
    }

    function _ringWalkForLiq(address token, uint256 id)
        internal view returns (bool found, uint128 markAtLiqUnits, uint16 ringStep)
    {
        Position storage p = _positions[id];
        if (p.user == address(0) || p.closed) return (false, 0, 0);
        MarkState storage st = _markState[token];
        if (st.lastPushAt == 0) return (false, 0, 0);
        ParamCatalog.TokenParams storage cfg = _params[token];

        uint128 markAtK  = st.currentMark;
        int128  indexAtK = FundingIndex.effectiveAt(st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp));
        uint64  timeAtK  = uint64(block.timestamp);
        int64   rate     = st.currentRate;

        if (_isLiquidatable(p, markAtK, indexAtK, cfg.structural.sizeTick, cfg.structural.notionalScale))
            return (true, markAtK, 0);

        uint256 head = st.ringHead;
        uint256 available = head < MarkRing.RING_LEN ? head : MarkRing.RING_LEN;
        for (uint256 k = 1; k <= available; k++) {
            uint256 idx = head - k;
            uint32 markE = MarkRing.readMarkEntry(_markRing[token], idx);
            if (MarkRing.isSentinel(markE)) return (false, 0, 0);
            (int256 priceDelta, uint256 timeDelta10) = MarkRing.unpackEntry(markE);
            uint64 durationSec = uint64(timeDelta10 * MarkRing.GAP_UNIT_MS / 1000);
            indexAtK = FundingIndex.stepBack(indexAtK, rate, durationSec);
            timeAtK  -= durationSec;
            int256 prev = int256(uint256(markAtK)) - priceDelta;
            if (prev <= 0) return (false, 0, 0);
            markAtK = uint128(uint256(prev));
            if (timeAtK >= p.openTime &&
                _isLiquidatable(p, markAtK, indexAtK, cfg.structural.sizeTick, cfg.structural.notionalScale)) {
                return (true, markAtK, uint16(k));
            }
            rate = MarkRing.readRateEntry(_rateRing[token], idx);
        }
        return (false, 0, 0);
    }

    function _isLiquidatable(
        Position storage p,
        uint128 markUnits,
        int128 indexAtK,
        uint256 sizeTick,
        uint256 notionalScale
    ) internal view returns (bool) {
        int256 fundingDelta = int256(indexAtK) - int256(p.fundingCheckpoint);
        if (!p.isLong) fundingDelta = -fundingDelta;
        int256 fundingPaid = (fundingDelta * int256(uint256(p.size) * sizeTick)) / int256(ParamCatalog.SCALE);
        int256 priceDiff = int256(uint256(markUnits)) - int256(uint256(p.entryPrice));
        if (!p.isLong) priceDiff = -priceDiff;
        int256 pnl = priceDiff * int256(uint256(p.size)) * int256(notionalScale);
        int256 effPnl = pnl - fundingPaid;
        if (effPnl >= 0) return false;
        return uint256(-effPnl) >= p.col;
    }

    // ---- Views ----

    function paramsOf(address token) external view override returns (ParamCatalog.TokenParams memory) {
        return _params[token];
    }
    function oracleOf(address token) external view override returns (address feed, uint8 decimals_, uint32 maxStale) {
        OracleConfig storage oc = _oracleConfig[token];
        return (oc.feed, oc.decimals, oc.maxStale);
    }
    function marketOf(address token) external view override returns (MarketView memory) {
        MarkState storage st = _markState[token];
        return MarketView({
            mark:             _priceOut(st.currentMark, _params[token].structural.priceTick),
            fundingIndex:     st.fundingIndex,
            currentRate:      st.currentRate,
            ringHead:         st.ringHead,
            openInterestLong:  openInterestLong[token],
            openInterestShort: openInterestShort[token]
        });
    }
    function rateRingAt(address token, uint16 idx) external view override returns (int64) {
        return MarkRing.readRateEntry(_rateRing[token], idx);
    }

    /// @notice Return a position with its live risk. `realizedPnl` is the *effective* PnL (net
    /// of funding); the gross PnL / funding split is recoverable from the `PositionClosed` event.
    /// `payoutReceived` is derived: `max(0, col + realizedPnl - makerCutPaid)`. `fundingOwed` and
    /// `liqPrice` are live (computed at the current mark) and read 0 once the position is closed.
    function positions(uint256 id) external view override returns (PositionView memory v) {
        Position storage p = _positions[id];
        ParamCatalog.Structural storage s = _params[p.token].structural;
        int256 effPnl_ = int256(p.realizedPnl);
        uint256 payout_;
        if (p.closed) {
            int256 net = int256(uint256(p.col)) + effPnl_ - int256(uint256(p.makerCutPaid));
            payout_ = net > 0 ? uint256(net) : 0;
        }
        v = PositionView({
            user:              p.user,
            token:             p.token,
            isLong:            p.isLong,
            size:              _sizeOut(p.size, s.sizeTick),
            leverage:          uint256(p.leverage),
            entryPrice:        _priceOut(p.entryPrice, s.priceTick),
            col:               uint256(p.col),
            fundingCheckpoint: p.fundingCheckpoint,
            openTime:          p.openTime,
            notionalAtOpen:    uint256(p.notionalAtOpen),
            closed:            p.closed,
            closeTime:         p.closeTime,
            closePrice:        _priceOut(p.closePrice, s.priceTick),
            realizedPnl:       effPnl_,
            makerCutPaid:      uint256(p.makerCutPaid),
            payoutReceived:    payout_,
            fundingOwed:       _fundingOwed(p, s),
            liqPrice:          _liqPrice(p, s)
        });
    }

    function _fundingOwed(Position storage p, ParamCatalog.Structural storage s) internal view returns (int256) {
        if (p.user == address(0) || p.closed) return 0;
        MarkState storage st = _markState[p.token];
        int128 indexNow = FundingIndex.effectiveAt(st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp));
        int256 delta = int256(indexNow) - int256(p.fundingCheckpoint);
        if (!p.isLong) delta = -delta;
        return (delta * int256(uint256(p.size) * s.sizeTick)) / int256(ParamCatalog.SCALE);
    }

    function _liqPrice(Position storage p, ParamCatalog.Structural storage s) internal view returns (uint256) {
        if (p.user == address(0) || p.closed) return 0;
        int256 fundingPaid = _fundingOwed(p, s);
        int256 denom = int256(uint256(p.size)) * int256(s.notionalScale);
        if (denom == 0) return 0;
        int256 delta = (int256(uint256(p.col)) + fundingPaid) / denom;
        int256 thresholdUnits = p.isLong
            ? int256(uint256(p.entryPrice)) - delta
            : int256(uint256(p.entryPrice)) + delta;
        if (thresholdUnits < 0) return 0;
        return uint256(thresholdUnits) * s.priceTick;
    }

    function reconstructAt(address token, uint16 entries) external view override returns (
        uint256 markAtK, int128 fundingAtK, uint64 timeAtK
    ) {
        MarkState storage st = _markState[token];
        uint64 nowT = uint64(block.timestamp);
        if (st.lastPushAt == 0 || entries == 0) {
            return (
                _priceOut(st.currentMark, _params[token].structural.priceTick),
                FundingIndex.effectiveAt(st.fundingIndex, st.currentRate, st.lastPushAt, nowT),
                nowT
            );
        }
        return _reconstructWalk(token, entries);
    }

    function _reconstructWalk(address token, uint16 entries) internal view returns (
        uint256 markAtK_1e18, int128 fundingAtK, uint64 timeAtK
    ) {
        MarkState storage st = _markState[token];
        ParamCatalog.Structural storage s = _params[token].structural;
        uint256 markAtKUnits = uint256(st.currentMark);
        fundingAtK = FundingIndex.effectiveAt(st.fundingIndex, st.currentRate, st.lastPushAt, uint64(block.timestamp));
        timeAtK    = uint64(block.timestamp);
        int64 rate = st.currentRate;

        uint256 head = st.ringHead;
        uint256 available = head < MarkRing.RING_LEN ? head : MarkRing.RING_LEN;
        uint256 limit = entries < available ? entries : available;
        for (uint256 k = 1; k <= limit; k++) {
            uint256 idx = head - k;
            uint32 me = MarkRing.readMarkEntry(_markRing[token], idx);
            if (MarkRing.isSentinel(me)) return (0, 0, 0);
            (int256 pDelta, uint256 td10) = MarkRing.unpackEntry(me);
            uint64 durationSec = uint64(td10 * MarkRing.GAP_UNIT_MS / 1000);
            fundingAtK = FundingIndex.stepBack(fundingAtK, rate, durationSec);
            timeAtK   -= durationSec;
            int256 prev = int256(markAtKUnits) - pDelta;
            if (prev <= 0) return (0, 0, 0);
            markAtKUnits = uint256(prev);
            rate = MarkRing.readRateEntry(_rateRing[token], idx);
        }
        markAtK_1e18 = markAtKUnits * s.priceTick;
    }
}
