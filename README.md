# THE ⨎ DRAINER (Lotus CLI)

Drain Filecoin (FIL) balances from one or more **source** addresses to a **destination** address using your own
**local Lotus node**. The script performs a **first sweep** (leaving a small reserve so gas can be paid),
waits for on‑chain confirmation, then sends a **top‑off sweep** to bring the source as close to **0 FIL**
as is safely practical.

> **Heads‑up on timing**  
> With conservative gas settings and explicit on‑chain waits, **two addresses can take up to ~5 minutes** end‑to‑end
> (≈ ~40s per sweep × 2 sweeps per address, plus network variability).

---

## ✨ What it does

- Reads balances from your local Lotus (`lotus wallet balance`).
- Sends a **first sweep** that leaves a small reserve (defaults ~`0.001 FIL`) so the message can pay fees.
- Waits for confirmation via `lotus state wait-msg` (local).  
  If local confirmation is slow/noisy, it falls back to a **balance delta check** before moving on.
- Sends **one top‑off** with a tighter reserve to minimize dust.
- Prints CIDs, gas settings, and confirmation summaries along the way.

> The drainer **never** sends more than the source can safely afford after reserving gas.
> If a send would risk *insufficient balance / out of gas*, it skips that send and moves on.

---

## ✅ Requirements

- A **synced Lotus full node** with the `lotus` CLI available (tested on `v1.32.x`).
- Standard Unix tools: `bash`, `awk`, `sed`, `grep`, `bc`, `timeout`, `jq`, `curl` (most distros ship these or install via package manager).
- Network connectivity (only for optional explorer lookups; sends/confirmation happen via your local Lotus).

---

## 🔧 Install

1. Copy `fildrainer.sh` into a directory on your Lotus machine.
2. Make it executable:
   ```bash
   chmod +x fildrainer.sh
   ```

> You’ll upload the script yourself; this repo contains only documentation.

---

## 🏃‍♀️ Quick Start

Drain two sources into one destination:

```bash
./fildrainer.sh -d <DEST_FIL_ADDRESS> \
  -s <SRC1_FIL_ADDRESS> \
  -s <SRC2_FIL_ADDRESS>
```

- `-d` / `--dest` — destination address (f1/f3/f4).
- `-s` / `--source` — a source address to drain (repeatable).

### Example (realistic output)

```text
./fildrainer.sh -d f1r7wdxfdncvllmkur6uakohq3vqv3fmmvtqzlbya -s f1zjdhcgx3jbbdsoo2ssj3yq44fzhpojrm4x2wb3a -s f3rboahog2hr3lh5js7tk2thszb2eugnkogyyrx7wdw27p7higpcuco7afyjnyit565d6d2yfqnvm3r5r7ybua 

T H E  ⨎  D R A I N E R

Destination address: f1r7wdxfdncvllmkur6uakohq3vqv3fmmvtqzlbya

⨎ Processing: f1zjdhcgx3jbbdsoo2ssj3yq44fzhpojrm4x2wb3a
 - Balance: 0.1 FIL (100000000000000000 attoFIL)
 - First sweep (reserve 0.001 FIL): 0.098998625 FIL
   Gas limit: 2750000, Fee cap: 500000 atto/gas, Premium: 200000 atto/gas
   Max fee bound: 0.000001375 FIL (1375000000000 attoFIL)
   Message CID: bafy2bzacea4iqtce5k7723r3gsgxjtm3msxapnfizqfqgg2wxb7qopkumf4fy
----------------------------------------
⨎ Processing: f3rboahog2hr3lh5js7tk2thszb2eugnkogyyrx7wdw27p7higpcuco7afyjnyit565d6d2yfqnvm3r5r7ybua
 - Balance: 0.010516526550152635 FIL (10516526550152635 attoFIL)
 - First sweep (reserve 0.001 FIL): 0.009515151550152636 FIL
   Gas limit: 2750000, Fee cap: 500000 atto/gas, Premium: 200000 atto/gas
   Max fee bound: 0.000001375 FIL (1375000000000 attoFIL)
   Message CID: bafy2bzacec2at3gk4roq525brgsvegavgk5kb2746ljqw22xps67bc5zs3i3k
----------------------------------------

🔎 Confirming first sweeps…
 - f1zjdhcgx3jbbdsoo2ssj3yq44fzhpojrm4x2wb3a  CID: bafy2bzacea4iqtce5k7723r3gsgxjtm3msxapnfizqfqgg2wxb7qopkumf4fy
   ✅ Confirmed (local).
   Top-off: 0.000899449725 FIL [limit=2750000, feecap=500000, premium=200000]
     CID: bafy2bzacectgo4cs4dd7agb7knp67n57pe4zhjojnnp2w73nabotmjoovvivs
     ✅ Confirmed. Gas Used: 1226263
 - f3rboahog2hr3lh5js7tk2thszb2eugnkogyyrx7wdw27p7higpcuco7afyjnyit565d6d2yfqnvm3r5r7ybua  CID: bafy2bzacec2at3gk4roq525brgsvegavgk5kb2746ljqw22xps67bc5zs3i3k
   ✅ Confirmed (local).
   Top-off: 0.000899449725 FIL [limit=2750000, feecap=500000, premium=200000]
     CID: bafy2bzaceaw2c7kks33uflifsajhahjn6dgalljrhgr5n2shfiw57tnwnffsc
     ✅ Confirmed. Gas Used: 1176863

🎉 Done.
```

> In practice, expect **up to ~5 minutes for two addresses** depending on node load and chain inclusion times.

---

## ⚙️ Defaults & knobs

These can be overridden via environment variables when you run the script:

| Variable | Default | Meaning |
|---|---:|---|
| `WAIT_SEC` | `40` | Seconds to wait for on‑chain confirmation (`lotus state wait-msg --timeout`). |
| `GAS_LIMIT` | `2750000` | Gas limit for simple transfers (padded for safety). |
| `GAS_FEE_CAP_ATTO` | `500000` | Fee cap (attoFIL/gas). |
| `GAS_PREMIUM_ATTO` | `200000` | Gas premium (attoFIL/gas). |
| `RESERVE_FIRST_FIL` | `0.001` | Reserve left on the first sweep so fees can be paid. |
| `RESERVE_TOPOFF_FIL` | `0.000899449725` | Reserve left after the top‑off sweep. |
| `MAX_TOPOFFS` | `1` | Number of top‑offs attempted per address (usually 1 is enough). |

Example override:
```bash
WAIT_SEC=30 GAS_FEE_CAP_ATTO=600000 GAS_PREMIUM_ATTO=220000 ./fildrainer.sh -d <DEST> -s <SRC>
```

---

## 🧠 How it chooses “how much to send”

1. Read **current balance** in attoFIL.  
2. Compute **max fee bound** = `GAS_LIMIT × GAS_FEE_CAP_ATTO`.  
3. **First sweep** amount = `balance - max_fee_bound - reserve_first`.  
   - If that would be ≤ 0, the address is skipped.  
4. After confirmation, recompute balance and attempt **one top‑off** = `balance - max_fee_bound - reserve_topoff`.  
5. Final balance should be only dust (close to 0, but still large enough to pay for any pending message costs).

This avoids *insufficient balance* and *SysErrOutOfGas* while keeping the address essentially empty.

---

## 🔍 Troubleshooting

- **“Confirmation not proven …”**  
  Local `wait-msg` occasionally times out even when the message has landed. The drainer then checks the **balance delta**; if it decreased by at least the send amount minus max fees, it treats the sweep as landed and proceeds.

- **“SysErrOutOfGas” or “insufficient balance”**  
  Increase `GAS_FEE_CAP_ATTO` and/or `GAS_LIMIT` a bit, or leave a slightly larger reserve (`RESERVE_FIRST_FIL`).

- **Stuck at “Pending lock (mpool)”**  
  You already have messages from that address in the mempool. Wait for them to land or bump `GAS_PREMIUM_ATTO`.

- **Very slow confirmations**  
  Raise `GAS_PREMIUM_ATTO` (priority fee) and, if needed, `GAS_FEE_CAP_ATTO`. Keep `WAIT_SEC` reasonable (30–60s).

- **Abort mid‑run**  
  `Ctrl + C` cleanly aborts the current wait and exits. Partial sweeps that already broadcast will still land on‑chain.

---

## 🔒 Safety & scope

- Only use with addresses **you control**.  
- The drainer never forces transactions that your balance can’t cover.  
- You can dry‑run your gas settings by running the script and watching the proposed amounts before confirmation.

---

## 📜 License

MIT — do what you want, no warranties.

---

## 🙌 Credits

Built around the Lotus CLI: `lotus wallet balance`, `lotus send`, and `lotus state wait-msg`.
Thanks to the many test iterations that helped tune safe fee caps and reserves.
