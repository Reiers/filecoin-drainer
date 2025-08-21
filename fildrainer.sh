#!/usr/bin/env bash
# T H E  ⨎  D R A I N E R — Lotus CLI edition (remote-first confirmation)
# - First sweep for each source (keeps reserve so gas can be paid), then a single top-off.
# - Confirmation is remote-first (Glif JSON-RPC) with short local wait-msg fallback.
# - All arithmetic in attoFIL integers. No floating math in bash.

set -euo pipefail
shopt -s extglob
LC_ALL=C

############### Tunables ###############
# Default/“safe” gas settings (used first)
GAS_LIMIT_DEFAULT=2750000         # gas units (safe for plain send, even new-account)
GAS_FEECAP_ATTO=500000            # attoFIL per gas (upper cap incl. basefee)
GAS_PREMIUM_ATTO=200000           # attoFIL per gas (priority tip)

# Compact fallback for near-dust balances (try to squeeze under fee bound)
GAS_LIMIT_COMPACT=1900000         # reduced gas limit (still OK for many sends)
GAS_FEECAP_COMPACT=400000         # smaller feecap
GAS_PREMIUM_COMPACT=180000        # slightly smaller premium

RESERVE_FIRST_FIL="0.001"         # leave on first pass
RESERVE_TOPUP_FIL="0.0001"        # leave on top-off
DUST_STOP_FIL="0.000001"          # skip if balance <= this (1e-6 FIL)

WAIT_SECS=40                      # remote confirmation window per CID
WAIT_POLL=2                       # seconds between remote polls
WAIT_LOCAL_FALLBACK=8             # extra local wait-msg window
WAIT_TOPUP_SECS=20                # wait-msg window for top-off confirmation
########################################

# Fast remote read-only node for confirmations
GLIF_RPC="${GLIF_RPC:-https://api.node.glif.io/rpc/v1}"

# Colors / banner
RST=$'\e[0m'; BLD=$'\e[1m'
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; DIM=$'\e[2m'

echo
echo "${BLD}T H E  ⨎  D R A I N E R${RST}"
echo

DEST=""
SOURCES=()
DRY_RUN=0

usage() {
  echo "Usage: $0 -d <dest> -s <source> [-s <source> ...] [--dry-run]"
  exit 1
}

# -------- argument parsing --------
while (( $# )); do
  case "$1" in
    -d|--dest)    DEST="${2:-}"; shift 2 ;;
    -s|--source)  SOURCES+=("${2:-}"); shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

[[ -z "$DEST" || ${#SOURCES[@]} -eq 0 ]] && usage

# -------- dependency checks --------
for d in lotus jq bc awk sed grep cut tr curl; do
  if ! command -v "$d" >/dev/null 2>&1; then
    echo "${RED}Missing dependency:${RST} $d"; exit 1
  fi
done

trap 'echo; echo "✖ Aborted by user"; exit 130' INT

# -------- helpers --------
sanitize_int() { local s="${1:-}"; s="${s//[^0-9]/}"; [[ -z "$s" ]] && echo 0 || echo "$s"; }

fil_to_atto() {
  local f="${1//[, ]/}" int frac
  if [[ "$f" == *.* ]]; then int="${f%%.*}"; frac="${f#*.}"; else int="$f"; frac=""; fi
  int="${int//[^0-9]/}"; frac="${frac//[^0-9]/}"
  frac="${frac}000000000000000000"; frac="${frac:0:18}"
  local out="${int}${frac}"; out="${out##+(0)}"
  [[ -z "$out" ]] && echo 0 || echo "$out"
}

atto_to_fil_trim() {
  local a; a="$(sanitize_int "${1:-0}")"; local len=${#a}
  (( len == 0 )) && { echo 0; return; }
  if (( len <= 18 )); then
    local frac; frac="$(printf "%018d" "$a")"; frac="${frac%%+([0])}"
    [[ -z "$frac" ]] && echo 0 || echo "0.${frac}"
    return
  fi
  local int="${a:0:len-18}" frac="${a:len-18}"; frac="${frac%%+([0])}"
  [[ -z "$frac" ]] && echo "$int" || echo "${int}.${frac}"
}

get_balance_atto() {
  local addr="$1"
  local out; out="$(lotus --color=false wallet balance "$addr" 2>/dev/null || true)"
  [[ -z "$out" ]] && { echo ""; return; }
  fil_to_atto "$(awk '{print $1}' <<<"$out")"
}

plan_send_json() {
  # inputs: balance_atto, reserve_atto, gas_limit, fee_cap_atto, premium_atto
  local bal_atto="$(sanitize_int "${1:-0}")"
  local reserve_atto="$(sanitize_int "${2:-0}")"
  local limit="$(sanitize_int "${3:-$GAS_LIMIT_DEFAULT}")"
  local feecap="$(sanitize_int "${4:-$GAS_FEECAP_ATTO}")"
  local premium="$(sanitize_int "${5:-$GAS_PREMIUM_ATTO}")"
  local fee_bound; fee_bound="$(echo "$limit * $feecap" | bc)"

  # need strictly more than fees + reserve
  if [[ "$(echo "$bal_atto <= ($fee_bound + $reserve_atto)" | bc)" == "1" ]]; then
    echo "{}"; return
  fi
  local send; send="$(echo "$bal_atto - $fee_bound - $reserve_atto" | bc)"
  (( send <= 0 )) && { echo "{}"; return; }

  jq -n --argjson s "$send" --argjson l "$limit" --argjson f "$feecap" --argjson p "$premium" \
     '{send:$s, limit:$l, feecap:$f, premium:$p}'
}

send_with_gas() {
  local from="$1" to="$2" amount_fil="$3" premium="$4" feecap="$5" limit="$6"
  lotus send --from "$from" \
             --gas-premium "$premium" \
             --gas-feecap "$feecap" \
             --gas-limit "$limit" \
             "$to" "$amount_fil"
}

rpc_search_msg() {
  # returns "ok:<exitCode>" when found; empty if not found yet
  local cid="$1"
  local req; req=$(jq -nc --arg cid "$cid" \
            '{jsonrpc:"2.0", id:1, method:"Filecoin.StateSearchMsg", params:[[], {"/":$cid}] }')
  local res; res="$(curl -s --max-time 6 -H 'Content-Type: application/json' -d "$req" "$GLIF_RPC" || true)"
  [[ -z "$res" ]] && return 1
  local ec; ec="$(jq -r '.result.Receipt.ExitCode // empty' <<<"$res" || true)"
  [[ -n "$ec" ]] && echo "ok:${ec}"
}

confirm_msg() {
  # echo "ok:remote" | "ok:local" | "fail:<code>"; return 0 when decided; return 1 if unknown
  local cid="$1" elapsed=0
  while (( elapsed < WAIT_SECS )); do
    local r; r="$(rpc_search_msg "$cid" || true)"
    if [[ -n "$r" ]]; then
      local ec="${r#ok:}"
      if [[ "$ec" == "0" ]]; then echo "ok:remote"; return 0; else echo "fail:$ec"; return 0; fi
    fi
    sleep "$WAIT_POLL"; elapsed=$((elapsed + WAIT_POLL))
  done
  # short local fallback
  local out; out="$(lotus state wait-msg --timeout="$WAIT_LOCAL_FALLBACK" "$cid" 2>&1 || true)"
  if grep -q 'Exit Code: 0' <<<"$out"; then echo "ok:local"; return 0; fi
  return 1
}

echo "Destination address: $DEST"
echo

DUST_ATTO="$(fil_to_atto "$DUST_STOP_FIL")"
RES1_ATTO="$(fil_to_atto "$RESERVE_FIRST_FIL")"
RES2_ATTO="$(fil_to_atto "$RESERVE_TOPUP_FIL")"

# Arrays must be initialized to avoid set -u “unbound variable”
CID_ARR=(); SRC_ARR=(); BAL0_ARR=()

# -------- First sweeps --------
for SRC in "${SOURCES[@]}"; do
  echo -e "${CYA}⨎ Processing:${RST} ${BLD}${SRC}${RST}"

  bal_atto="$(get_balance_atto "$SRC")"
  if [[ -z "$bal_atto" ]]; then
    echo -e " - ${YEL}Failed to fetch balance. Skipping.${RST}"
    echo "----------------------------------------"; continue
  fi
  echo -e " - Balance: ${GRN}$(atto_to_fil_trim "$bal_atto") FIL${RST} (${DIM}${bal_atto} attoFIL${RST})"

  if [[ "$(echo "$bal_atto <= $DUST_ATTO" | bc)" == "1" ]]; then
    echo -e " - ${DIM}Below dust threshold; skipping.${RST}"
    echo "----------------------------------------"; continue
  fi

  # Primary plan
  plan="$(plan_send_json "$bal_atto" "$RES1_ATTO" "$GAS_LIMIT_DEFAULT" "$GAS_FEECAP_ATTO" "$GAS_PREMIUM_ATTO")"

  # If not enough, try compact fallback
  if ! jq -e '.send' >/dev/null 2>&1 <<<"$plan"; then
    plan="$(plan_send_json "$bal_atto" "$RES1_ATTO" "$GAS_LIMIT_COMPACT" "$GAS_FEECAP_COMPACT" "$GAS_PREMIUM_COMPACT")"
  fi

  if ! jq -e '.send' >/dev/null 2>&1 <<<"$plan"; then
    echo -e " - ${YEL}Not enough to lock fees + reserve. Skipping.${RST}"
    echo "----------------------------------------"; continue
  fi

  send_atto="$(sanitize_int "$(jq -r '.send' <<<"$plan")")"
  limit="$(sanitize_int "$(jq -r '.limit' <<<"$plan")")"
  feecap="$(sanitize_int "$(jq -r '.feecap' <<<"$plan")")"
  premium="$(sanitize_int "$(jq -r '.premium' <<<"$plan")")"
  send_fil="$(atto_to_fil_trim "$send_atto")"
  maxfee="$(echo "$limit * $feecap" | bc)"

  echo -e " - First sweep (reserve ${RESERVE_FIRST_FIL} FIL): ${GRN}${send_fil} FIL${RST}"
  echo -e "   Gas limit: ${limit}, Fee cap: ${feecap} atto/gas, Premium: ${premium} atto/gas"
  echo -e "   Max fee bound: ${DIM}$(atto_to_fil_trim "$maxfee") FIL${RST} (${DIM}${maxfee} attoFIL${RST})"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "   ${DIM}[dry-run] would send${RST}"
    echo "----------------------------------------"; continue
  fi

  out="$(send_with_gas "$SRC" "$DEST" "$send_fil" "$premium" "$feecap" "$limit" 2>&1 || true)"
  cid="$(grep -Eo 'bafy[0-9a-z]{40,}' <<<"$out" | head -n1 || true)"
  if [[ -z "$cid" ]]; then
    echo -e "   ${RED}❌ Send failed:${RST} ${out//$'\n'/ }"
    echo "----------------------------------------"; continue
  fi

  echo -e "   Message CID: ${DIM}${cid}${RST}"
  CID_ARR+=("$cid"); SRC_ARR+=("$SRC"); BAL0_ARR+=("$bal_atto")
  echo "----------------------------------------"
done

# Guard: if nothing sent, exit cleanly (avoid unbound/empty references)
if (( ${#CID_ARR[@]} == 0 )); then
  echo -e "\n${DIM}No messages to confirm.${RST}\n🎉 Done."
  exit 0
fi

# -------- Confirm first sweeps (remote-first) & do top-off --------
echo -e "\n${CYA}🔎 Confirming first sweeps…${RST}"
for i in "${!CID_ARR[@]}"; do
  cid="${CID_ARR[$i]}"; src="${SRC_ARR[$i]}"; bal0="${BAL0_ARR[$i]}"
  echo -e " - ${DIM}${src}${RST}  CID: ${DIM}${cid}${RST}"

  confirmed=0
  if r="$(confirm_msg "$cid")"; then
    case "$r" in
      ok:remote) echo -e "   ${GRN}✅ Confirmed (remote).${RST}"; confirmed=1 ;;
      ok:local)  echo -e "   ${GRN}✅ Confirmed (local).${RST}"; confirmed=1 ;;
      fail:*)    echo -e "   ${RED}✖ On-chain ExitCode ${r#fail:}.${RST}"; confirmed=0 ;;
    esac
  fi

  if (( confirmed==0 )); then
    echo -e "   ${YEL}⚠️  Not proven, checking balance delta…${RST}"
    sleep 2
    bal_now="$(get_balance_atto "$src")"; [[ -z "$bal_now" ]] && bal_now="0"
    if [[ "$(echo "$bal_now < $bal0" | bc)" == "1" ]]; then
      echo -e "   ${GRN}✓ Balance dropped to $(atto_to_fil_trim "$bal_now") FIL — assuming landed.${RST}"
      confirmed=1
    else
      echo -e "   ${DIM}No delta; skipping top-off for this source.${RST}"
    fi
  fi

  if (( confirmed==1 )); then
    # One top-off with primary plan; if too tight, try compact
    bal_now="${bal_now:-$(get_balance_atto "$src")}"
    [[ -z "$bal_now" ]] && bal_now="0"
    if [[ "$(echo "$bal_now <= $(fil_to_atto "$DUST_STOP_FIL")" | bc)" == "1" ]]; then
      echo -e "   ${DIM}(near zero, no top-off)${RST}"
      continue
    fi

    plan2="$(plan_send_json "$bal_now" "$RES2_ATTO" "$GAS_LIMIT_DEFAULT" "$GAS_FEECAP_ATTO" "$GAS_PREMIUM_ATTO")"
    if ! jq -e '.send' >/dev/null 2>&1 <<<"$plan2"; then
      plan2="$(plan_send_json "$bal_now" "$RES2_ATTO" "$GAS_LIMIT_COMPACT" "$GAS_FEECAP_COMPACT" "$GAS_PREMIUM_COMPACT")"
    fi
    if jq -e '.send' >/dev/null 2>&1 <<<"$plan2"; then
      send2_atto="$(sanitize_int "$(jq -r '.send' <<<"$plan2")")"
      if (( send2_atto > 0 )); then
        limit2="$(sanitize_int "$(jq -r '.limit' <<<"$plan2")")"
        feecap2="$(sanitize_int "$(jq -r '.feecap' <<<"$plan2")")"
        premium2="$(sanitize_int "$(jq -r '.premium' <<<"$plan2")")"
        send2_fil="$(atto_to_fil_trim "$send2_atto")"
        echo -e "   Top-off: ${GRN}${send2_fil} FIL${RST} [limit=${limit2}, feecap=${feecap2}, premium=${premium2}]"
        out2="$(send_with_gas "$src" "$DEST" "$send2_fil" "$premium2" "$feecap2" "$limit2" 2>&1 || true)"
        cid2="$(grep -Eo 'bafy[0-9a-z]{40,}' <<<"$out2" | head -n1 || true)"
        if [[ -n "$cid2" ]]; then
          echo -e "     CID: ${DIM}${cid2}${RST}"
          outc="$(lotus state wait-msg --timeout="$WAIT_TOPUP_SECS" "$cid2" 2>&1 || true)"
          if grep -q 'Exit Code: 0' <<<"$outc"; then
            gas2="$(grep -Eo 'Gas Used: [0-9]+' <<<"$outc" | awk '{print $3}')"; [[ -z "$gas2" ]] && gas2="?"
            echo -e "     ${GRN}✅ Confirmed.${RST} Gas Used: ${DIM}${gas2}${RST}"
          else
            echo -e "     ${DIM}(not proven in ${WAIT_TOPUP_SECS}s — will settle naturally)${RST}"
          fi
        else
          echo -e "     ${DIM}(top-off send returned no CID — skipped)${RST}"
        fi
      fi
    fi
  fi
done

echo -e "\n🎉 Done."
