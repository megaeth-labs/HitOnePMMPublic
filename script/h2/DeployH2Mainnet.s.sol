// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// H2 — MegaETH MAINNET (chain 4326) deploy: H2Oracle, H2Market, BuilderRegistry, then per market
// createFeed + createMarket + the seed deposit.
//
// Env-driven and logged before broadcast so every value can be reviewed in the dry run. Parameters
// are built by H2MainnetParams.sol (shared with CheckH2Rules.s.sol, which evaluates
// src/h2/DEPLOY_RULES.md against them, warn-only). Policy lives there and in the rules, not here.
//
// Roles: the BROADCASTER deploys and is every market's creator and the holder of the seed LP
// shares (not transferable), so it should be a cold wallet. OPERATOR pushes marks and receives the
// rake; it defaults to the broadcaster.
//
// Run it through the wrapper, which adds the preflight these scripts cannot do (feed age,
// balances, settlement token, hardware-wallet signing):
//   cp script/h2/mainnet.env.example script/h2/mainnet.env   # fill in
//   source script/h2/mainnet.env
//   script/h2/mainnet-deploy.sh               # preflight + rules table + DRY RUN
//   script/h2/mainnet-deploy.sh --broadcast   # for real

import { console2 }        from "forge-std/Script.sol";
import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata }  from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { H2Oracle }        from "../../src/h2/H2Oracle.sol";
import { H2Market }        from "../../src/h2/H2Market.sol";
import { BuilderRegistry } from "../../src/h2/BuilderRegistry.sol";
import { IH2Market }       from "../../src/h2/IH2Market.sol";
import { IAggregatorV3 }   from "../../src/common/IAggregatorV3.sol";
import { H2MainnetParams } from "./H2MainnetParams.sol";

contract DeployH2Mainnet is H2MainnetParams {
    // ---- required env ------------------------------------------------------
    //   USDM                 18-decimal settlement token (NOT a mock)
    //   MARKET_TOKENS        comma-separated token addresses, one per market
    //   FALLBACK_FEEDS       comma-separated AggregatorV3 feeds (RedStone/Bolt), one per market
    //   PRICE_TICKS          comma-separated, 1e18-scale price quantum per market
    //   SIZE_TICKS           comma-separated, 1e18-scale size quantum per market
    // ---- optional env (defaults unless noted) -------------------------------
    //   OPERATOR             feed operator / rake recipient (default: broadcaster)
    //   REF_FEEDS            comma-separated reference feeds for the band check; omit = same as FALLBACK_FEEDS
    //   REF_BAND_PPM         |mark - ref| band (default 10_000 = 1%)
    //   REF_MAX_STALE        reference max age, seconds (default 21_600 = 6h)
    //   FEE_RAKE_PPM         operator rake on pool gains (default 150_000 = 15%)
    //   MAX_RATE_PER_SEC     feed funding-rate magnitude cap (default 1.5e15)
    //   BOOTSTRAP_USDM       per-vault first-LP deposit in USDM wei (default 0 = skip; deployer must hold it)
    //   BUILDER_REGISTRY     existing registry address; "0" disables builder codes;
    //                        unset = deploy a fresh BuilderRegistry(BUILDER_STAKE_TOKEN, BUILDER_MIN_STAKE)
    //   BUILDER_STAKE_TOKEN  0 = native ETH (default), else ERC-20 (e.g. MEGA)
    //   BUILDER_MIN_STAKE    default 0.01 ether
    //   MAX_DEVIATION_PPM    primary-vs-fallback both-fresh gate (default 10_000 = 1%; v5 testnet ran 100)
    //   FALLBACK_MAX_AGE     seconds (default 60)
    //   PRIMARY_STALE_SECS   seconds before the fallback path arms (default 300)
    //   MAX_SPREAD_PPM       cap on the derived spread (default 5_000; 0 = no derived spread at all)
    //   SPREAD_OPEN_VOL_K / SPREAD_OPEN_SKEW_K / SPREAD_CLOSE_VOL_K / SPREAD_CLOSE_SKEW_K (default 0)
    //   MIN_ADJUST_GAP_BLOCKS (default 1)   MAX_BUILDER_FEE_PPM (default 100_000)
    //   EXPECT_CHAIN_ID      default 4326 — override ONLY to dry-run this script elsewhere

    function run() external {
        uint256 expectChain = vm.envOr("EXPECT_CHAIN_ID", uint256(4326));
        require(block.chainid == expectChain, "wrong chain");

        address usdm = vm.envAddress("USDM");
        address[] memory tokens    = vm.envAddress("MARKET_TOKENS", ",");
        address[] memory fallbacks = vm.envAddress("FALLBACK_FEEDS", ",");
        uint256[] memory priceTicks = vm.envUint("PRICE_TICKS", ",");
        uint256[] memory sizeTicks  = vm.envUint("SIZE_TICKS", ",");
        address[] memory refs = vm.envOr("REF_FEEDS", ",", fallbacks);
        uint256 n = tokens.length;
        require(n > 0, "MARKET_TOKENS empty");
        require(fallbacks.length == n && priceTicks.length == n && sizeTicks.length == n && refs.length == n,
            "per-market env lists must have equal length");

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
        address operator = vm.envOr("OPERATOR", msg.sender);
        require(operator != address(0), "OPERATOR zero");
        if (bootstrap > 0) {
            require(IERC20(usdm).balanceOf(msg.sender) >= bootstrap * n, "deployer lacks BOOTSTRAP_USDM * n");
        }

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

    /// A fallback feed that has never answered (or answers <= 0) would misprice every fallback fill.
    function _assertFresh(address feed) internal view {
        (, int256 answer, , uint256 updatedAt, ) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "fallback feed answer <= 0");
        require(updatedAt > 0, "fallback feed never updated");
    }
}
