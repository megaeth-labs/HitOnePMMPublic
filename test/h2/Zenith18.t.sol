// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #18 — a winning close whose gross profit outruns the liquid pool no longer reverts
/// `Insolvent`. The owed-winnings queue (PR 2) pays what is liquid and enqueues the rest, senior to
/// LPs; the pool still ends at the exact NET debit (gross profit less its share of the fees).
contract Zenith18 is H2MarketTest {
    uint256 internal _nn = 1000;

    function _ord(uint256 pk, uint256 m, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 target)
        internal returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen, size: size, leverage: lev,
            targetPrice: target, maxSlippageBps: 500, deadline: uint64(block.timestamp + 365 days),
            channel: 7, nonce: _nn++, builder: address(0), builderFeePpm: 0
        });
    }

    /// 1 BTC 100x long 50,000 → 51,000 on a fresh market seeded with `seed`. At the close: effPnl
    /// 1,000, winnings cut 55 (46.75 to the pool after the 15% rake), close fee 25.5 (21.675 to the
    /// pool). The open fee credited 21.25 to the pool at the open.
    function _closeOn(uint256 seed) internal returns (uint256 m, uint256 id) {
        vm.prank(op);
        m = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(reg));
        _seedTreasury(m, seed);
        _adv(1);
        IH2Market.Order memory o = _ord(alicePk, m, true, true, 1e18, 100, 50_000e18);
        _pushOrderM(m, 50_000e18, o, _sign(alicePk, o), 0, 0);
        id = h.activePositionId(alice, m);
        _adv(1);
        IH2Market.Order memory c = _ord(alicePk, m, true, false, 1e18, 0, 51_000e18);
        _pushOrderM(m, 51_000e18, c, _sign(alicePk, c), 0, 0);
    }

    // Zenith's scenario: pool 960 at the close (938.75 seed + 21.25 open fee) is below the gross
    // 1,000 profit but covers the net debit of 953.25. The audited code reverted `Insolvent`.
    function test_F18_fundableCloseSettlesOnNetDebit() public {
        (uint256 m, uint256 id) = _closeOn(938.75e18);
        assertTrue(h.positions(id).closed, "fundable close settles");
        // The pool drains its liquid 960 and collects 68.425 of fees (80.5 net of the 15% rake);
        // the 40 the drain could not cover is owed to alice, senior to LPs.
        assertEq(h.vaultOf(m).poolAssets, 68.425e18, "pool holds the fees it collected");
        assertEq(h.owedOf(m), 40e18, "shortfall enqueued as owed");
        (address user,, , uint256 claimable) = h.owedEntry(m, 0);
        assertEq(user, alice); assertEq(claimable, 40e18, "fully funded by the collected fees");
        vm.prank(alice); assertEq(h.claimWinnings(m, 0), 40e18);
        // 960 + 21.675 (close fee, net of rake) + 46.75 (cut, net of rake) − 1,000
        assertEq(h.vaultOf(m).poolAssets, 28.425e18, "pool ends at the exact net");
        assertEq(h.owedOf(m), 0);
    }

    function test_F18_unfundableCloseEnqueuesInsteadOfReverting() public {
        // pool 921.25 at the close: 921.25 + 21.675 + 46.75 = 989.675 < 1,000 — the audited code
        // (and the net-debit reorder) left this close stuck; now it settles and owes the difference.
        (uint256 m, uint256 id) = _closeOn(900e18);
        assertTrue(h.positions(id).closed, "a genuinely unfundable win still settles");
        assertEq(h.vaultOf(m).poolAssets, 68.425e18, "pool drained to its collected fees");
        assertEq(h.owedOf(m), 78.75e18, "1,419.5 net entitlement - 1,340.75 paid");
        (,,, uint256 claimable) = h.owedEntry(m, 0);
        assertEq(claimable, 68.425e18, "only the funded frontier is claimable");
        vm.prank(alice); assertEq(h.claimWinnings(m, 0), 68.425e18);
        assertEq(h.owedOf(m), 10.325e18, "remainder waits for the pool to refill");
    }

    function test_F18_finalBalancesUnchangedWhenAmplyFunded() public {
        (uint256 m, uint256 id) = _closeOn(10_000e18);
        assertTrue(h.positions(id).closed);
        assertEq(h.owedOf(m), 0, "nothing owed when the pool covers the gross");
        // 10,000 + 21.25 + 21.675 + 46.75 − 1,000
        assertEq(h.vaultOf(m).poolAssets, 9_089.675e18, "same final pool as before");
    }
}
