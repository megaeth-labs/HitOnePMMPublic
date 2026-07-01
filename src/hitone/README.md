# HitOne venue

This directory will hold the HitOne-specific perp venue contract. It's intentionally a sibling of `src/iso/`, not a subclass — auditors should be able to read `HitOneMarket.sol` end-to-end without chasing virtual functions across files.

## What's shared (via `src/common/`)

| Module | Purpose |
|---|---|
| `MarkRing.sol`     | Packed mark + parallel rate ring primitives |
| `FundingIndex.sol` | Lazy funding accumulator + step-back math |
| `Slippage.sol`     | Two-coefficient skew curve |
| `IAggregatorV3.sol`| Chainlink-shape oracle interface |
| `ParamCatalog.sol` | Per-token parameter struct + structural validation |

## What's HitOne-specific (in this folder)

- `HitOneMarket.sol` — main contract (TBD when specs land)
- `IHitOneMarket.sol` — interface (TBD)

## Handoff plan

At handoff, `src/common/` + `src/hitone/` + corresponding tests get extracted to HitOne's own repo. HitOne owns deployment, admin keys, audit pipeline. We (the MM) remain whichever role HitOne assigns us (typically `maker`).
