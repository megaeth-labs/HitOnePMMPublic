// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// H2 — MegaETH MAINNET (chain 4326) deploy: H2Oracle, H2Market, BuilderRegistry, then per market
// createFeed + createMarket + the seed deposit (7 transactions for the one BTC market).
//
// Everything it deploys is in H2MainnetParams.sol; no env file. Before broadcasting it prints the
// deployment-rules table (CheckH2Rules, warn-only) and checks what the chain must already hold:
// USDm with 18 decimals, the deployer's USDm seed, the deployer not blacklisted, a fresh RedStone
// answer, market tokens with code.
//
// Dry run (simulates all 7 transactions, sends nothing):
//   forge script script/h2/DeployH2Mainnet.s.sol --rpc-url https://mainnet.megaeth.com/rpc \
//     --sender <deployer> --disable-code-size-limit
// Deploy, signing on a hardware wallet (Foundry >= 1.8.6 for Trezor; add --resume to finish a
// partial run instead of starting over):
//   forge script script/h2/DeployH2Mainnet.s.sol --rpc-url https://mainnet.megaeth.com/rpc \
//     --sender <deployer> --disable-code-size-limit --broadcast \
//     --trezor --mnemonic-derivation-paths "m/44'/60'/0'/0/0"       # or --ledger

import { console2 }        from "forge-std/Script.sol";
import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata }  from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { H2Oracle }        from "../../src/h2/H2Oracle.sol";
import { H2Market }        from "../../src/h2/H2Market.sol";
import { BuilderRegistry } from "../../src/h2/BuilderRegistry.sol";
import { IH2Market }       from "../../src/h2/IH2Market.sol";
import { IAggregatorV3 }   from "../../src/common/IAggregatorV3.sol";
import { H2MainnetParams } from "./H2MainnetParams.sol";
import { CheckH2Rules }    from "./CheckH2Rules.s.sol";

interface IBlacklistable { function isBlacklisted(address account) external view returns (bool); }

contract DeployH2Mainnet is H2MainnetParams {
    // Every value comes from H2MainnetParams.sol. Each getter there also reads an env var of the
    // same name (USDM, MARKET_TOKENS, FALLBACK_FEEDS, BOOTSTRAP_USDM, OPERATOR, ...) as an override
    // for tests and other deployments; BUILDER_REGISTRY: unset = fresh registry, 0 = disabled.

    function run() external {
        require(block.chainid == _chainId(), "wrong chain");

        address usdm = _usdm();
        address[] memory tokens     = _tokens();
        address[] memory fallbacks  = _fallbacks();
        uint256[] memory priceTicks = _priceTicks();
        uint256[] memory sizeTicks  = _sizeTicks();
        address[] memory refs       = _refs();
        uint256 n = tokens.length;
        require(n > 0, "no markets");
        require(fallbacks.length == n && priceTicks.length == n && sizeTicks.length == n && refs.length == n,
            "per-market lists must have equal length");

        // Deployment rules, warn-only: a WARN line is for the deployer to read, not a stop.
        new CheckH2Rules().run();

        // ---- settlement token sanity: real, 18-decimal, has code ----
        require(usdm.code.length > 0, "USDM has no code");
        require(IERC20Metadata(usdm).decimals() == 18, "USDM must be 18 decimals");

        uint32  refBandPpm   = _refBandPpm();
        uint32  refMaxStale  = _refMaxStale();
        uint32  feeRakePpm   = _feeRakePpm();
        uint64  maxRate      = _maxRate();
        uint256 bootstrap    = _bootstrap();

        IH2Market.FeeParams    memory fees   = _fees();
        IH2Market.SpreadParams memory spread = _spread();

        vm.startBroadcast();
        address operator = _operator();
        require(operator != address(0), "OPERATOR zero");
        _preflight(usdm, operator, bootstrap * n, tokens);

        H2Oracle oracle = new H2Oracle();
        H2Market market = new H2Market(usdm, address(oracle));
        address registry = _resolveRegistry();
        console2.log("chain            ", block.chainid);
        console2.log("deployer         ", msg.sender);
        console2.log("operator         ", operator);
        console2.log("USDM             ", usdm);
        console2.log("H2Oracle         ", address(oracle));
        console2.log("H2Market         ", address(market));
        console2.log("BuilderRegistry  ", registry);
        console2.log("feeRakePpm       ", feeRakePpm);
        console2.log("refBandPpm       ", refBandPpm);
        console2.log("refMaxStale      ", refMaxStale);
        console2.log("bootstrap/vault  ", bootstrap);

        if (bootstrap > 0) IERC20(usdm).approve(address(market), bootstrap * n);

        for (uint256 i = 0; i < n; i++) {
            require(tokens[i] != address(0), "zero token");
            require(fallbacks[i].code.length > 0, "fallback feed has no code");
            require(refs[i].code.length > 0, "ref feed has no code");
            uint8 fbDec  = IAggregatorV3(fallbacks[i]).decimals(); // pinned by the contracts
            uint8 refDec = IAggregatorV3(refs[i]).decimals();
            _assertFresh(fallbacks[i]);

            uint256 feedId = oracle.createFeed(
                operator, priceTicks[i], maxRate, feeRakePpm, refs[i], refDec, refBandPpm, refMaxStale
            );
            require(feedId == i + 1, "feed id drift");

            IH2Market.RiskParams   memory risk = _risk(priceTicks[i], sizeTicks[i]);
            IH2Market.OracleParams memory op   = _oracleParams(uint64(feedId), fallbacks[i], fbDec);

            uint256 marketId = market.createMarket(tokens[i], fees, risk, op, spread, registry);
            require(marketId == feedId, "market id drift");
            if (bootstrap > 0) market.deposit(marketId, bootstrap);

            console2.log("market", marketId, "token", tokens[i]);
            console2.log("  fallback", fallbacks[i], "decimals", fbDec);
            console2.log("  priceTick", priceTicks[i], "sizeTick", sizeTicks[i]);
        }
        vm.stopBroadcast();
    }

    /// BUILDER_REGISTRY: unset => deploy the reference registry; "0" => disabled; else reuse.
    function _resolveRegistry() internal returns (address) {
        address existing = vm.envOr("BUILDER_REGISTRY", address(type(uint160).max));
        if (existing == address(0)) return address(0);
        if (existing != address(type(uint160).max)) {
            require(existing.code.length > 0, "BUILDER_REGISTRY has no code");
            return existing;
        }
        return address(new BuilderRegistry(_stakeToken(), _minStake()));
    }

    /// What the chain must already hold before the first transaction. View calls only, so nothing
    /// here is broadcast.
    function _preflight(address usdm, address operator, uint256 seedTotal, address[] memory tokens)
        internal view
    {
        console2.log("preflight");
        console2.log("  deployer ETH (wei)  ", msg.sender.balance);
        console2.log("  operator ETH (wei)  ", operator.balance);
        if (operator.balance < 0.002 ether) console2.log("  NOTE operator below 0.002 ETH: it cannot push marks until funded");
        uint256 held = IERC20(usdm).balanceOf(msg.sender);
        console2.log("  deployer USDM       ", held);
        console2.log("  seed needed         ", seedTotal);
        require(held >= seedTotal, "deployer lacks the USDM seed (BOOTSTRAP_USDM * markets)");
        // USDm's issuer can blacklist; absent on other tokens, so a missing function is fine.
        try IBlacklistable(usdm).isBlacklisted(msg.sender) returns (bool listed) {
            require(!listed, "deployer is blacklisted on the settlement token");
        } catch {}
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && tokens[i].code.length > 0, "market token has no code");
        }
    }

    /// A fallback feed that has never answered, answers <= 0, or is more than a minute off the
    /// block time would misprice every fallback fill. RedStone stamps updatedAt in microseconds.
    function _assertFresh(address feed) internal view {
        (, int256 answer, , uint256 updatedAt, ) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "fallback feed answer <= 0");
        require(updatedAt > 0, "fallback feed never updated");
        uint256 t = updatedAt > 1e14 ? updatedAt / 1e6 : updatedAt > 1e11 ? updatedAt / 1e3 : updatedAt;
        require(t + 60 >= block.timestamp && t <= block.timestamp + 60, "fallback feed stale or future-stamped");
    }
}
