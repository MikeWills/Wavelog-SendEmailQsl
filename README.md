# QSL Card Mailer — WX0MIK

Polls Wavelog for new QSOs and sends an HTML email with your QSL card
(inline + attachment) to each contact that has an email address on record.

---

## Requirements

- PowerShell 7+ (`pwsh`) on Linux
- Wavelog with callbook lookup enabled (so QSOs include EMAIL and NAME fields)
- A read-only Wavelog API key

---

## Directory Layout

```
qsl-mailer/
├── Send-QslCards.ps1       # Main script
├── config.json             # Your settings (never commit passwords)
├── card_assignments.json   # Per-callsign card overrides
├── state.json              # Auto-created; tracks last fetched QSO ID
├── cards/
│   ├── my_qsl_card.jpg     # Default pool card(s) — add as many as you want
│   └── special_card.png    # Can be assigned to specific callsigns
└── logs/
    └── qsl-mailer-YYYY-MM.log
```

---

## Setup

1. **Clone / copy** this folder to your Linux server.

2. **Add QSL card images** into the `cards/` folder (JPEG or PNG).

3. **Edit `config.json`**:
   - `wavelog.url` — your Wavelog base URL, including `/index.php` (e.g.
     `https://logbook.example.com/index.php`); no trailing slash needed
   - `wavelog.api_key` — a **read-only** key from Wavelog → User Menu → API Keys
   - `wavelog.station_id` — found in the URL when editing a Station Profile
   - Fill in `station` and `smtp` sections
   - `smtp.reply_to` (optional) — if replies should go to a different address
     than `smtp.from_address`, set it here

4. **Edit `card_assignments.json`** (optional):  
   Map specific callsigns to specific card filenames.  
   Callsigns not listed get a random card from the remaining pool.

5. **Test run** (dry run — no emails sent, state.json not updated):
   ```bash
   pwsh ./Send-QslCards.ps1 -DryRun
   ```

6. **Test run** (live):
   ```bash
   pwsh ./Send-QslCards.ps1
   ```

---

## Starting on an Existing Logbook

If you're enabling this on a logbook that already has a lot of QSOs, a normal
first run will try to email every existing contact that has an `EMAIL` field.
To start fresh from "now" instead, run:

```bash
pwsh ./Send-QslCards.ps1 -MarkCaughtUp
```

This fetches all pending QSOs, advances `state.json` to the most recent one,
and exits — no emails are sent and no cards are selected. Future runs will
only process QSOs logged after this point.

---

## Cron Setup

Run every hour (adjust as needed):

```bash
crontab -e
```

Add:
```
0 * * * * /usr/bin/pwsh /home/youruser/qsl-mailer/Send-QslCards.ps1 >> /home/youruser/qsl-mailer/logs/cron.log 2>&1
```

Find your `pwsh` path with: `which pwsh`

---

## How Card Selection Works

| Situation | Card Used |
|---|---|
| Callsign listed in `card_assignments.json` | That specific card |
| Assigned card file is missing | Falls back to random pool |
| No assignment | Random card from pool |
| Pool empty (all cards are assigned) | Random from full set |

---

## Important Notes

- **Email requires the NAME/EMAIL fields** to be present in the QSO. These are
  only populated if Wavelog performs a callbook lookup (QRZ, HamQTH, etc.).
  QSOs without an email address are logged as skipped.

- **State is tracked in `state.json`** (`last_qso_id`). Delete this file to
  reprocess all QSOs from the beginning (useful for initial testing).

- The script uses **Wavelog's `APP_WAVELOG_LOGID`** ADIF field to track
  position. If Wavelog doesn't export this field, state won't advance and the
  script will re-fetch all QSOs every run. Check your Wavelog version —
  this field was added in recent releases.

---

## References

- Wavelog API docs: https://docs.wavelog.org/developer/api/
- `api/get_contacts_adif` endpoint (fetchfromid): https://docs.wavelog.org/developer/api/#apiget_contacts_adif
