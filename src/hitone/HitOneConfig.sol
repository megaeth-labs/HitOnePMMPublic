// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable }        from "@openzeppelin/contracts/access/Ownable.sol";

import { IHitOneMarket }  from "./IHitOneMarket.sol";
import { ParamCatalog }   from "../common/ParamCatalog.sol";

/// @title HitOneConfig
/// @notice Validation + TIMELOCK for the market's owner-set params (`setToken`, `setOracle`), in
/// front of the market's raw `apply*` setters. These are the "context" that protects users, so
/// changes are timelocked by `market.roleChangeDelay()` (= 2× `withdrawDelay`). The FIRST
/// registration of a token and the FIRST oracle set are instant, so launch isn't blocked for a
/// delay; every change after that is timelocked.
///
/// Single ownership root: owner-gated calls check the MARKET's owner (`market.owner()`) — one
/// `owner`, one `transferOwnership`. The market authorizes this contract by address
/// (`market.configurator()`). A misbehaving configurator can only grief params, never move funds.
/// Housing this validation + timelock here (not on the market) keeps the market under EIP-170.
///
/// NOTE: per-maker `setRiskLimits` is NOT here — makers call `market.setRiskLimits` directly
/// (permissionless, instant); it protects the maker's own book, so it isn't owner-timelocked.
contract HitOneConfig {
    IHitOneMarket public immutable market;
    uint256 internal immutable _usdmDenom;

    mapping(address => bool) public tokenInitialized;   // structural set at least once
    mapping(address => bool) public oracleInitialized;  // oracle set at least once

    struct Pending {
        uint8   kind;       // 0 = structural, 1 = oracle
        address token;
        ParamCatalog.Structural structural;                              // kind 0
        address feed; uint8 decimals; uint32 maxStale; uint16 maxDevBps; // kind 1
        uint64  readyAt;
        bool    exists;
    }
    mapping(uint256 => Pending) internal _pending;
    uint256 public nextConfigChangeId;

    event StructuralQueued(uint256 indexed id, address indexed token, uint64 readyAt);
    event OracleQueued(uint256 indexed id, address indexed token, uint64 readyAt);
    event ConfigChangeExecuted(uint256 indexed id);
    event ConfigChangeCancelled(uint256 indexed id);

    error NotOwner();
    error UnknownToken();
    error ZeroAddress();
    error BadOracleConfig();
    error ConfigChangeUnknown();
    error ConfigChangeNotReady();

    constructor(address market_) {
        if (market_ == address(0)) revert ZeroAddress();
        market = IHitOneMarket(market_);
        _usdmDenom = 10 ** uint256(IERC20Metadata(address(IHitOneMarket(market_).usdm())).decimals());
    }

    modifier onlyMarketOwner() {
        if (msg.sender != Ownable(address(market)).owner()) revert NotOwner();
        _;
    }

    /// @notice Owner curates the token's structural grid. First registration instant; changes
    /// (incl. deregister, `priceTick == 0`) timelocked. `notionalScale` is derived here.
    function setToken(address token, ParamCatalog.Structural calldata structural) external onlyMarketOwner {
        if (token == address(0)) revert ZeroAddress();
        ParamCatalog.Structural memory s = structural;
        if (s.priceTick != 0) ParamCatalog.validateAndDeriveStructural(s, _usdmDenom);
        if (!tokenInitialized[token]) {
            if (s.priceTick == 0) revert UnknownToken();   // can't deregister an unregistered token
            tokenInitialized[token] = true;
            market.applyStructural(token, s);
        } else {
            uint256 id = ++nextConfigChangeId;
            Pending storage p = _pending[id];
            p.kind = 0; p.token = token; p.structural = s;
            p.readyAt = uint64(block.timestamp + market.roleChangeDelay()); p.exists = true;
            emit StructuralQueued(id, token, p.readyAt);
        }
    }

    /// @notice Owner sets the per-token oracle band (user-protection). First set instant; changes
    /// (incl. disabling via `feed == 0`) timelocked. See `script/hitone/RedStoneFeeds.sol`.
    function setOracle(address token, address feed, uint8 decimals, uint32 maxStale, uint16 maxDevBps)
        external onlyMarketOwner
    {
        if (market.structuralOf(token).priceTick == 0) revert UnknownToken();
        if (feed != address(0) &&
            (decimals > 18 || maxStale == 0 || maxDevBps == 0 || maxDevBps > ParamCatalog.BPS_DENOM))
            revert BadOracleConfig();
        if (!oracleInitialized[token]) {
            oracleInitialized[token] = true;
            market.applyOracle(token, feed, decimals, maxStale, maxDevBps);
        } else {
            uint256 id = ++nextConfigChangeId;
            Pending storage p = _pending[id];
            p.kind = 1; p.token = token;
            p.feed = feed; p.decimals = decimals; p.maxStale = maxStale; p.maxDevBps = maxDevBps;
            p.readyAt = uint64(block.timestamp + market.roleChangeDelay()); p.exists = true;
            emit OracleQueued(id, token, p.readyAt);
        }
    }

    /// @notice Apply a queued owner-param change once its delay has elapsed. Permissionless — it was
    /// already owner-committed at queue time; `cancelConfigChange` is the owner's undo.
    function executeConfigChange(uint256 id) external {
        Pending memory p = _pending[id];
        if (!p.exists)                   revert ConfigChangeUnknown();
        if (block.timestamp < p.readyAt) revert ConfigChangeNotReady();
        delete _pending[id];
        if (p.kind == 0) market.applyStructural(p.token, p.structural);
        else             market.applyOracle(p.token, p.feed, p.decimals, p.maxStale, p.maxDevBps);
        emit ConfigChangeExecuted(id);
    }
    function cancelConfigChange(uint256 id) external onlyMarketOwner {
        if (!_pending[id].exists) revert ConfigChangeUnknown();
        delete _pending[id];
        emit ConfigChangeCancelled(id);
    }
    function pendingConfigChange(uint256 id)
        external view returns (uint8 kind, address token, uint64 readyAt, bool exists)
    {
        Pending memory p = _pending[id];
        return (p.kind, p.token, p.readyAt, p.exists);
    }
}
