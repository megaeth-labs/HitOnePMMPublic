// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { HitOneStorage }     from "./HitOneStorage.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";

/// @title HitOneAdmin
/// @notice Owner/maker/pauser admin surface, maker-pool collateral flows and config views.
abstract contract HitOneAdmin is HitOneStorage {
    using SafeERC20 for IERC20;

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

    // ---- Views ----

    function paramsOf(address token) external view override returns (ParamCatalog.TokenParams memory) {
        return _params[token];
    }
    function oracleOf(address token) external view override returns (address feed, uint8 decimals_, uint32 maxStale) {
        OracleConfig storage oc = _oracleConfig[token];
        return (oc.feed, oc.decimals, oc.maxStale);
    }
}
