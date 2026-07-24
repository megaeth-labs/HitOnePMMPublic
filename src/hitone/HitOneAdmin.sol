// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { HitOneStorage }     from "./HitOneStorage.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";

/// @title HitOneAdmin
/// @notice Admin surface: owner token curation, timelocked halter role, per-maker self-service
/// risk + funder, and per-maker segregated pool flows.
abstract contract HitOneAdmin is HitOneStorage {
    using SafeERC20 for IERC20;

    // ---- Roles (timelocked) ----

    /// @notice Effective delay on owner role changes: twice the withdrawal delay.
    function roleChangeDelay() public view override returns (uint256) {
        return 2 * withdrawDelay;
    }

    function queueSetHalter(address h, bool allowed) external override onlyOwner returns (uint256 id) {
        if (h == address(0)) revert ZeroAddress();
        id = _queueRole(2, address(0), h, allowed);
    }

    /// @notice Bootstrap the configurator — instant while unset (deploy-time wiring). Swapping it
    /// afterwards is timelocked (`queueSetConfigurator`). A config contract can only grief params.
    function setConfigurator(address c) external override onlyOwner {
        if (configurator != address(0)) revert ConfiguratorAlreadySet();
        if (c == address(0)) revert ZeroAddress();
        configurator = c;
        emit ConfiguratorSet(c);
    }
    function queueSetConfigurator(address c) external override onlyOwner returns (uint256 id) {
        if (c == address(0)) revert ZeroAddress();
        id = _queueRole(3, address(0), c, false);
    }

    function _queueRole(uint8 kind, address subject, address account, bool allowed) internal returns (uint256 id) {
        id = ++_nextRoleChangeId;
        uint64 readyAt = uint64(block.timestamp + roleChangeDelay());
        _pendingRoles[id] = PendingRoleChange({
            kind: kind, subject: subject, account: account, allowed: allowed, readyAt: readyAt, exists: true
        });
        emit RoleChangeQueued(id, kind, subject, account, allowed, readyAt);
    }

    /// @notice Apply a queued role change once its delay has elapsed. Permissionless — the change
    /// was already owner-committed at queue time; `cancelRoleChange` is the owner's undo.
    function executeRoleChange(uint256 id) external override {
        PendingRoleChange memory r = _pendingRoles[id];
        if (!r.exists)                   revert RoleChangeUnknown();
        if (block.timestamp < r.readyAt) revert RoleChangeNotReady();
        delete _pendingRoles[id];
        // kind 3 = configurator swap; else halter grant/revoke. (Makers self-register + self-fund.)
        if (r.kind == 3) { configurator = r.account; emit ConfiguratorSet(r.account); }
        else             { isHalter[r.account] = r.allowed; emit HalterSet(r.account, r.allowed); }
        emit RoleChangeExecuted(id);
    }
    function cancelRoleChange(uint256 id) external override onlyOwner {
        if (!_pendingRoles[id].exists) revert RoleChangeUnknown();
        delete _pendingRoles[id];
        emit RoleChangeCancelled(id);
    }
    function pendingRoleChange(uint256 id)
        external view override
        returns (uint8 kind, address subject, address account, bool allowed, uint64 readyAt, bool exists)
    {
        PendingRoleChange memory r = _pendingRoles[id];
        return (r.kind, r.subject, r.account, r.allowed, r.readyAt, r.exists);
    }

    /// @notice A maker sets its own treasury (funder) key. While unset the maker is its own funder;
    /// once set, only the current funder may rotate it — giving hot-maker / cold-funder separation.
    /// Pass address(0) to revert to maker-as-funder.
    function setMakerFunder(address maker, address funder) external override onlyMakerFunder(maker) {
        makerFunder[maker] = funder;
        emit MakerFunderSet(maker, funder);
    }

    function setWithdrawDelay(uint256 d) external override onlyOwner {
        if (d < WITHDRAW_DELAY_MIN || d > WITHDRAW_DELAY_MAX) revert BadWithdrawDelay();
        withdrawDelay = d;
        emit WithdrawDelaySet(d);
    }

    /// @notice Write validated structural params for `token` (configurator only). `priceTick == 0`
    /// deregisters. Validation + the owner-param timelock live in `HitOneConfig`.
    function applyStructural(address token, ParamCatalog.Structural calldata structural)
        external override onlyConfigurator
    {
        if (structural.priceTick == 0) {
            delete _params[token];
            ParamCatalog.Structural memory empty;
            emit TokenSet(token, empty);
        } else {
            _params[token].structural = structural;
            emit TokenSet(token, structural);
        }
    }

    /// @notice A maker sets the risk limits for its OWN book on `token`. Permissionless — anyone
    /// may run a maker book on an owner-registered token; a maker's book is inert until this is set
    /// (default caps leave `maxPositionNotional` at 0, which blocks opens).
    function setRiskLimits(address token, MakerRisk calldata riskIn) external override {
        if (_params[token].structural.priceTick == 0) revert UnknownToken();
        MakerRisk memory risk = riskIn;
        if (risk.maxPositionNotional == 0) risk.maxPositionNotional = DEFAULT_MAX_POSITION_NOTIONAL;
        if (risk.maxOIGross == 0)          risk.maxOIGross          = type(uint256).max;
        if (risk.maxOISkew == 0)           risk.maxOISkew           = type(uint256).max;
        // linearScale/quadScale are size-fee multipliers ("bps at $1M notional"); 0 = off, no default.
        if (risk.openFeeBps > ParamCatalog.MAX_FEE_BPS) revert BadFee();
        _makerRisk[msg.sender][token] = risk;
        emit RiskLimitsSet(msg.sender, token, risk);
    }

    /// @notice Write the validated oracle band for `token` (configurator only; `feed == 0` disables).
    function applyOracle(address token, address feed, uint8 decimals_, uint32 maxStale, uint16 maxDevBps)
        external override onlyConfigurator
    {
        _oracleConfig[token] = OracleConfig({ feed: feed, decimals: decimals_, maxStale: maxStale, maxDevBps: maxDevBps });
        emit OracleSet(token, feed, decimals_, maxStale, maxDevBps);
    }

    /// @notice Emergency halt. Callable ONLY by a halter — not makers, funders, or the owner.
    /// Sets a fresh `HALT_COOLDOWN` window; re-calling while halted pushes `haltedUntil` out.
    function halt() external override {
        if (!isHalter[msg.sender]) revert NotHalter();
        halted = true;
        haltedUntil = uint64(block.timestamp + HALT_COOLDOWN);
        emit Halted(msg.sender, haltedUntil);
    }
    /// @notice Lift the halt. Halter only, and only once the cooldown has elapsed.
    function unhalt() external override {
        if (!isHalter[msg.sender])         revert NotHalter();
        if (!halted)                       revert NotHalted();
        if (block.timestamp < haltedUntil) revert HaltCooldownActive();
        halted = false;
        emit Unhalted(msg.sender);
    }
    function setPausedNew(bool paused_) external override {
        if (!isHalter[msg.sender] && msg.sender != owner()) revert NotPausedNewAuth();
        pausedNew = paused_;
        emit PausedNew(paused_);
    }

    // ---- Collateral (per-maker segregated pools) ----

    function fundMakerPool(address maker, address token, uint256 amount)
        external override onlyMakerFunder(maker) nonReentrant
    {
        usdm.safeTransferFrom(msg.sender, address(this), amount);
        collateral[maker][token] += amount;
        emit MakerPoolFunded(maker, msg.sender, token, amount);
    }
    function queueWithdrawMakerPool(address maker, address token, uint256 amount, address to)
        external override onlyMakerFunder(maker) returns (uint256 id)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount > collateral[maker][token]) revert Insolvent();
        if (amount > type(uint128).max) revert BadSize();
        id = ++_nextWithdrawalId;
        uint64 readyAt = uint64(block.timestamp + withdrawDelay);
        _pendingWithdrawals[id] = PendingWithdrawal({
            maker: maker, token: token, to: to, amount: uint128(amount), readyAt: readyAt, exists: true
        });
        emit MakerPoolWithdrawalQueued(id, maker, token, to, amount, readyAt);
    }
    function executeWithdrawMakerPool(uint256 id) external override nonReentrant {
        PendingWithdrawal memory w = _pendingWithdrawals[id];
        if (!w.exists)                   revert WithdrawalUnknown();
        if (block.timestamp < w.readyAt) revert WithdrawalNotReady();
        delete _pendingWithdrawals[id];
        uint256 bal = collateral[w.maker][w.token];
        if (w.amount > bal) revert Insolvent();
        unchecked { collateral[w.maker][w.token] = bal - w.amount; }
        usdm.safeTransfer(w.to, w.amount);
        emit MakerPoolWithdrawalExecuted(id);
    }
    /// @notice Cancel a pending withdrawal. Funder-gated (the pool's own funder), NOT owner — so
    /// an adversarial owner cannot trap a maker's queued exit.
    function cancelWithdrawMakerPool(uint256 id) external override {
        PendingWithdrawal memory w = _pendingWithdrawals[id];
        if (!w.exists) revert WithdrawalUnknown();
        if (msg.sender != makerFunder[w.maker]) revert NotFunder();
        delete _pendingWithdrawals[id];
        emit MakerPoolWithdrawalCancelled(id);
    }
    function pendingMakerPoolWithdrawal(uint256 id)
        external view override
        returns (address maker, address token, address to, uint256 amount, uint64 readyAt, bool exists)
    {
        PendingWithdrawal memory w = _pendingWithdrawals[id];
        return (w.maker, w.token, w.to, uint256(w.amount), w.readyAt, w.exists);
    }

    // ---- Views ----

    function structuralOf(address token) external view override returns (ParamCatalog.Structural memory) {
        return _params[token].structural;
    }
    function makerRiskOf(address maker, address token) external view override returns (MakerRisk memory) {
        return _makerRisk[maker][token];
    }
    function oracleOf(address token)
        external view override returns (address feed, uint8 decimals_, uint32 maxStale, uint16 maxDevBps)
    {
        OracleConfig storage oc = _oracleConfig[token];
        return (oc.feed, oc.decimals, oc.maxStale, oc.maxDevBps);
    }
}
