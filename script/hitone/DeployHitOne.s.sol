// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { Script, console2 } from "forge-std/Script.sol";
import { HitOneMarket }     from "../../src/hitone/HitOneMarket.sol";
import { ParamCatalog }     from "../../src/common/ParamCatalog.sol";
import { MockERC20 }        from "../../test/mocks/MockERC20.sol";

/// @notice Testnet deploy for the HitOneMarket venue. The deployer owns during bring-up and is
/// granted a temporary maker role so it can seed the maker pool and push the initial mark;
/// both are revoked before ownership is handed to MM_OWNER. USDM + token are reused from env if
/// provided.
///
/// Env vars (required):
///   DEPLOYER_PRIVATE_KEY
///   MM_OWNER
///   SIGNER_PUBLIC_KEY            — set as the persistent maker (sole on-chain order submitter)
///
/// Env vars (optional):
///   USDM_ADDR                    — reuse existing USDM (else deploys a MockERC20)
///   TOKEN_ADDR                   — reuse existing market token (else deploys a MockERC20)
///   TOKEN_TICK                   — defaults to 1e18 ($1)
///   TOKEN_OPEN_FEE_BPS           — defaults to 0
///   TOKEN_MIN_LEVERAGE           — defaults to 100
///   TOKEN_MAX_LEVERAGE           — defaults to 1000
///   INITIAL_MARK                 — defaults to 50_000e18
///   MAKER_POOL_SEED              — defaults to 100_000e18 (USDM minted + funded into the pool)
///
/// Run:
///   set -a; source .env; set +a
///   forge script script/hitone/DeployHitOne.s.sol:DeployHitOne --rpc-url <RPC> --broadcast -vv
contract DeployHitOne is Script {
    function run() external {
        uint256 pk          = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address mmOwner     = vm.envAddress("MM_OWNER");
        address signer      = vm.envAddress("SIGNER_PUBLIC_KEY");

        address usdmAddr    = _envAddressOr("USDM_ADDR", address(0));
        address tokenAddr   = _envAddressOr("TOKEN_ADDR", address(0));

        uint256 tick        = _envUintOr("TOKEN_TICK",         1e18);
        uint256 openFee     = _envUintOr("TOKEN_OPEN_FEE_BPS", 0);
        uint256 minLev      = _envUintOr("TOKEN_MIN_LEVERAGE", 100);
        uint256 maxLev      = _envUintOr("TOKEN_MAX_LEVERAGE", 1000);
        uint256 initialMark = _envUintOr("INITIAL_MARK",       50_000e18);
        uint256 poolSeed    = _envUintOr("MAKER_POOL_SEED",    100_000e18);

        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. USDM (deploy MockERC20 if not provided).
        MockERC20 usdm;
        if (usdmAddr == address(0)) {
            usdm = new MockERC20();
            console2.log("Deployed USDM (MockERC20):", address(usdm));
        } else {
            usdm = MockERC20(usdmAddr);
            console2.log("Using existing USDM:", address(usdm));
        }

        // 2. HitOneMarket. Deployer owns during bring-up; signer is the persistent maker.
        HitOneMarket hit = new HitOneMarket(deployer, signer, address(usdm));
        console2.log("Deployed HitOneMarket:", address(hit));
        console2.log("Persistent maker:", signer);

        // 3. Market token.
        address market;
        if (tokenAddr == address(0)) {
            // HitOne holds collateral in USDM and never calls the token contract, so for testnet
            // the token only needs a valid address.
            market = address(new MockERC20());
            console2.log("Deployed market token (MockERC20):", market);
        } else {
            market = tokenAddr;
            console2.log("Using existing market token:", market);
        }

        // 4. Register the token (onlyOwner — deployer).
        ParamCatalog.TokenParams memory params = ParamCatalog.TokenParams({
            structural: ParamCatalog.Structural({
                priceTick:           tick,            // $1 step (with 18-dec USDM)
                sizeTick:            1e10,            // 1 sat step (BTC convention)
                notionalScale:       0,               // derived in setToken
                minLeverage:         minLev,
                maxLeverage:         maxLev,
                maxPositionDuration: 30 days,
                cutIntercept:        0,
                cutSlopeBps:         550,
                maxCutBps:           550
            }),
            risk: ParamCatalog.Risk({
                openFeeBps:          openFee,
                linearScale:         type(uint256).max,  // unused by HitOne (maker fill + band)
                quadScale:           type(uint256).max,  // unused by HitOne
                maxPositionNotional: 0,                  // 0 => default 200_000e18
                maxOIGross:          0,
                maxOISkew:           0,
                maxDevBps:           0
            })
        });
        hit.setToken(market, params);
        console2.log("Registered token. tick:", tick, "openFeeBps:", openFee);

        // 5. Temporary maker rights for the deployer to seed the pool + push the initial mark.
        hit.setMaker(deployer, true);

        // 6. Seed the maker pool (fundMakerPool is onlyMaker, pulls USDM from msg.sender).
        if (poolSeed > 0) {
            usdm.mint(deployer, poolSeed);
            usdm.approve(address(hit), poolSeed);
            hit.fundMakerPool(market, poolSeed);
            console2.log("Seeded maker pool:", poolSeed);
        }

        // 7. Initial mark push (setMark is onlyMaker).
        hit.setMark(market, initialMark);
        console2.log("Initial mark:", initialMark);

        // 8. Revoke the deployer's temporary maker role.
        hit.setMaker(deployer, false);

        // 9. Hand ownership over to MM_OWNER.
        hit.transferOwnership(mmOwner);
        console2.log("Ownership transferred to MM_OWNER:", mmOwner);

        vm.stopBroadcast();

        console2.log("");
        console2.log("---- DEPLOY SUMMARY ----");
        console2.log("HitOneMarket: ", address(hit));
        console2.log("USDM:         ", address(usdm));
        console2.log("Market token: ", market);
        console2.log("Owner:        ", mmOwner);
        console2.log("Maker:        ", signer);
    }

    // ---- helpers ----

    function _envAddressOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; } catch { return fallback_; }
    }
    function _envUintOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) { return v; } catch { return fallback_; }
    }
}
