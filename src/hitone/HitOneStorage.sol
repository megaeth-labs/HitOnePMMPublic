// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata }    from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 }            from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { IHitOneMarket }     from "./IHitOneMarket.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";

/// @title HitOneStorage
/// @notice Shared storage layout, constants, immutables, modifiers and tick helpers for
/// HitOneMarket. All state lives here so the layout is unambiguous across the inheritance tree.
abstract contract HitOneStorage is IHitOneMarket, Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    address public constant override MAKER_POOL                = address(0);
    uint256 public constant override MAKER_POOL_WITHDRAW_DELAY = 48 hours;

    /// @dev Minimum time a halt must stay live before `unhalt` is permitted.
    uint256 public constant override HALT_COOLDOWN = 20 minutes;

    uint256 internal constant DEFAULT_MAX_POSITION_NOTIONAL = 200_000e18;

    /// @dev MegaETH high-precision-timestamp system contract (µs since epoch, slot 0).
    address internal constant HP_TIMESTAMP = 0x6342000000000000000000000000000000000002;

    uint256 internal constant UNITS_CAP = 1 << 96;

    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address user,address token,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce)"
    );

    IERC20 public immutable override usdm;
    uint256 internal immutable _usdmDenom;
    address public override funder;
    address public override halter;
    bool    public override pausedNew;
    bool    public override halted;
    uint64  public override haltedUntil;   // earliest timestamp `unhalt` may succeed

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
        uint64  lastPushAt;   // seconds (block.timestamp) — funding clock
        uint64  ringHead;
        int128  fundingIndex;
        int64   currentRatePct;  // signed fixed-point funding rate, ±1%/sec across int64 (see setMarkAndRate)
        uint64  lastPushMs;   // milliseconds (HP wall-clock) — ring/liveness clock
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

    modifier onlyMaker()  { if (!isMaker[msg.sender]) revert NotMaker();  _; }
    modifier onlyFunder() { if (msg.sender != funder) revert NotFunder(); _; }
    modifier whenNotHalted() {
        if (halted) revert MarketHalted();
        _;
    }
    modifier whenNotPausedNew() {
        if (pausedNew) revert PausedNewOpens();
        _;
    }

    constructor(address usdm_) {
        if (usdm_ == address(0)) revert ZeroAddress();
        usdm = IERC20(usdm_);
        _usdmDenom = 10 ** uint256(IERC20Metadata(usdm_).decimals());
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
}
