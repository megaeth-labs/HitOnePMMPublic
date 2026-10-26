#!/usr/bin/env bash
# mainnet-deploy.sh — H2 mainnet deploy with the preflight the scripts themselves cannot do
# (balances, feed freshness, operator sanity, settlement token).
#
#   source script/h2/mainnet.env
#   script/h2/mainnet-deploy.sh            # preflight + DRY RUN (no state change)
#   script/h2/mainnet-deploy.sh --broadcast # for real
#
# Settlement is a REAL token: USDM and MARKET_TOKENS must be set, and the deployer must already
# HOLD BOOTSTRAP_USDM × n. After a real run the addresses are in
# broadcast/DeployH2Mainnet.s.sol/<chain id>/run-latest.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:-dry}"
RPC="${RPC_4326:?source script/h2/mainnet.env first}"
: "${DEPLOYER_ADDR:?}" "${OPERATOR:?}" "${FALLBACK_FEEDS:?}"
REAL_USDM="${USDM:?USDM (the settlement token) must be set}"
# Who signs: `key` = DEPLOYER_KEY; `ledger` / `trezor` = a hardware wallet (mainnet:
# the deployer is the market creator and holds the non-transferable seed shares, so it should be
# the cold wallet). Hardware mode needs DEPLOYER_ADDR (+ DEPLOYER_HD_PATH if not the first account)
# and signs each deploy tx on the device; the dry run only simulates as --sender.
SIGNER="${DEPLOYER_SIGNER:-key}"
HD_PATH="${DEPLOYER_HD_PATH:-}"; [ -n "$HD_PATH" ] || HD_PATH="m/44'/60'/0'/0/0"

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERR %s\033[0m\n' "$*" >&2; exit 1; }
lower(){ printf %s "$1" | tr A-Z a-z; }

say "Preflight ($RPC)"
CID=$(cast chain-id --rpc-url "$RPC"); [ "$CID" = "${EXPECT_CHAIN_ID:-4326}" ] || die "chain id $CID"
case "$SIGNER" in
  key)
    : "${DEPLOYER_KEY:?DEPLOYER_SIGNER=key needs DEPLOYER_KEY}"
    DERIVED=$(cast wallet address --private-key "$DEPLOYER_KEY")
    [ "$(lower "$DERIVED")" = "$(lower "$DEPLOYER_ADDR")" ] || die "DEPLOYER_KEY derives to $DERIVED, not $DEPLOYER_ADDR"
    SIGN_FLAGS=(--private-key "$DEPLOYER_KEY") ;;
  ledger|trezor)
    [ -z "${DEPLOYER_KEY:-}" ] || die "DEPLOYER_SIGNER=$SIGNER but DEPLOYER_KEY is set — unset it, the hot key must not sign this"
    # The device: Ethereum app open, blind signing ON (contract creation on an unknown chain id).
    if DERIVED=$(cast wallet address "--$SIGNER" --mnemonic-derivation-path "$HD_PATH" 2>/dev/null); then
      [ "$(lower "$DERIVED")" = "$(lower "$DEPLOYER_ADDR")" ] || die "$SIGNER at $HD_PATH is $DERIVED, not $DEPLOYER_ADDR"
      echo "  $SIGNER $HD_PATH = $DEPLOYER_ADDR  (device connected)"
    elif [ "$MODE" = "--broadcast" ]; then die "$SIGNER not reachable at $HD_PATH — connect it, open the Ethereum app, enable blind signing"
    else echo "  !! $SIGNER not reachable — dry run simulates as --sender $DEPLOYER_ADDR; the broadcast needs the device"; fi
    SIGN_FLAGS=(--sender "$DEPLOYER_ADDR")
    [ "$MODE" = "--broadcast" ] && SIGN_FLAGS+=("--$SIGNER" --mnemonic-derivation-paths "$HD_PATH") ;;
  *) die "DEPLOYER_SIGNER must be key, ledger or trezor (got '$SIGNER')" ;;
esac
DB=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC"); OB=$(cast balance "$OPERATOR" --rpc-url "$RPC")
GP=$(cast gas-price --rpc-url "$RPC")
echo "  deployer $DEPLOYER_ADDR  balance $(cast from-wei "$DB") ETH"
echo "  operator $OPERATOR  balance $(cast from-wei "$OB") ETH"
# MegaETH prices code deposit steeply: the one-market deploy estimates ~575M gas (H2Market's CREATE
# is most of it). At the 0.001 gwei floor that is still < 0.001 ETH.
echo "  gas price $GP wei  (deploy ~575M gas => ~$(python3 -c "print($GP*575_000_000/1e18)") ETH)"
# Fallback / reference feed: code, decimals, positive answer, updated within the last minute.
NOW=$(cast block latest -f timestamp --rpc-url "$RPC")
for F in ${FALLBACK_FEEDS//,/ }; do
  [ "$(cast code "$F" --rpc-url "$RPC")" != "0x" ] || die "feed $F has no code"
  OUT=$(cast call "$F" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC")
  ANS=$(printf '%s\n' "$OUT" | sed -n 2p | cut -d' ' -f1); UPD=$(printf '%s\n' "$OUT" | sed -n 4p | cut -d' ' -f1)
  UPDS=$(python3 -c "t=$UPD; print(t//1_000_000 if t>1e14 else t//1000 if t>1e11 else t)")
  AGE=$((NOW - UPDS)); DEC=$(cast call "$F" 'decimals()(uint8)' --rpc-url "$RPC")
  echo "  feed $F  dec=$DEC  answer=$ANS  age=${AGE}s"
  [ "$ANS" -gt 0 ] || die "feed answer <= 0"; [ "$AGE" -le 60 ] && [ "$AGE" -ge -60 ] || die "feed stale/future (age ${AGE}s)"
done
NEED=$((GP * 575000000 * 2))   # 2x headroom on the estimate
if [ "$MODE" = "--broadcast" ]; then
  # (python: wei balances overflow bash's 64-bit test above 9.2 ETH)
  [ "$(python3 -c "print(int($DB) >= int($NEED))")" = True ] || die "deployer $DEPLOYER_ADDR needs >= $(cast from-wei $NEED) ETH for the deploy (has $(cast from-wei $DB))"
  [ "$(python3 -c "print(int($OB) > 0)")" = True ] || echo "  !! operator $OPERATOR has 0 ETH — the MM cannot push marks until it is funded (~0.005 ETH/day per market at a 3 s cadence, tip 0)"
fi

# Settlement token: the things DeployH2Mainnet.s.sol would only discover at broadcast
# (code, 18 decimals, the deployer's balance) plus what it cannot see (issuer blacklist).
if [ -n "$REAL_USDM" ]; then
  : "${MARKET_TOKENS:?MARKET_TOKENS must be set (one market token per market)}"
  [ "$(cast code "$REAL_USDM" --rpc-url "$RPC")" != "0x" ] || die "USDM $REAL_USDM has no code"
  USYM=$(cast call "$REAL_USDM" 'symbol()(string)' --rpc-url "$RPC" | tr -d '"')
  UDEC=$(cast call "$REAL_USDM" 'decimals()(uint8)' --rpc-url "$RPC")
  UBAL=$(cast call "$REAL_USDM" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDR" --rpc-url "$RPC" | cut -d' ' -f1)
  NMK=$(python3 -c "print(len('$MARKET_TOKENS'.split(',')))")
  NEEDU=$(python3 -c "print(${BOOTSTRAP_USDM:-0} * $NMK)")
  echo "  settlement $REAL_USDM  $USYM  dec=$UDEC  deployer holds $(cast from-wei "$UBAL") (needs $(cast from-wei "$NEEDU") = BOOTSTRAP_USDM x $NMK)"
  [ "$UDEC" = "18" ] || die "USDM must be 18 decimals (H2Market refuses anything else)"
  # Issuer blacklist (USDm = xUSDOFTUpgradeable has isBlacklisted(address)); absent on other tokens.
  if BL=$(cast call "$REAL_USDM" 'isBlacklisted(address)(bool)' "$DEPLOYER_ADDR" --rpc-url "$RPC" 2>/dev/null); then
    [ "$BL" = "false" ] || die "deployer $DEPLOYER_ADDR is blacklisted on $USYM"
  else
    echo "  (no isBlacklisted() on $USYM)"
  fi
  if [ "$(python3 -c "print(int($UBAL) >= int($NEEDU))")" != "True" ]; then
    if [ "$MODE" = "--broadcast" ]; then die "deployer lacks BOOTSTRAP_USDM x $NMK of $USYM — fund $DEPLOYER_ADDR first";
    else echo "  !! deployer lacks the bootstrap $USYM — the broadcast will refuse until $DEPLOYER_ADDR is funded"; fi
  fi
  for T in ${MARKET_TOKENS//,/ }; do
    [ "$(cast code "$T" --rpc-url "$RPC")" != "0x" ] || die "market token $T has no code"
    echo "  market token $T  $(cast call "$T" 'symbol()(string)' --rpc-url "$RPC" | tr -d '"')  (identity only; H2Market never transfers it)"
  done
fi

# Deployment rules (src/h2/DEPLOY_RULES.md) against the exact params the deploy will use. Warn-only:
# a WARN line is for the deployer to read and resolve, the script does not stop on it.
say "Rules (src/h2/DEPLOY_RULES.md, warn-only)"
forge script script/h2/CheckH2Rules.s.sol --rpc-url "$RPC" -vv 2>&1 | awk '/== Logs ==/{f=1; next} f && /^$/{exit} f' || true

FLAGS=(--rpc-url "$RPC" "${SIGN_FLAGS[@]}" --disable-code-size-limit -vv)
[ "$MODE" = "--broadcast" ] && FLAGS+=(--broadcast)
[ "$MODE" = "--broadcast" ] && [ "$SIGNER" != key ] && echo "  (hardware wallet: confirm each tx on the device — the deploy is $((3 + 3 * $(printf %s "${MARKET_TOKENS:-x}" | tr ',' '\n' | wc -l | tr -d ' '))) txs, ~0.0006 ETH total; forge waits per tx)"

say "Deploy: DeployH2Mainnet.s.sol ${MODE}"
forge script script/h2/DeployH2Mainnet.s.sol "${FLAGS[@]}"
[ "$MODE" = "--broadcast" ] && { say "Done. Addresses: broadcast/DeployH2Mainnet.s.sol/$CID/run-latest.json"; }
exit 0
