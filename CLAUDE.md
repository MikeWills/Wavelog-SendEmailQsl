# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-script PowerShell tool (`Send-QslCards.ps1`) that polls a Wavelog logbook
instance for new QSOs and emails each contact an HTML QSL card confirmation
(inline image + attachment). Intended to run on a schedule (cron) on Linux
with PowerShell 7+.

## Running / testing

```bash
pwsh ./Send-QslCards.ps1 -DryRun   # logs what would be sent, no SMTP send
pwsh ./Send-QslCards.ps1           # live run
```

Always update the readme with relavant changes. Always do a security check. Always review project for unused code an remove.

- `-ConfigPath` can override the default `config.json` location (defaults to
  the script's own directory).
- There is no test suite, build step, or linter — verification is via
  `-DryRun` runs against a real (or test) Wavelog instance.
- Delete `state.json` to force reprocessing of all QSOs from the beginning.

## Architecture / flow (all in `Send-QslCards.ps1`)

1. **Config & state** — loads `config.json` (Wavelog URL/API key/station ID,
   station identity, SMTP creds) and `state.json` (`last_qso_id`, auto-created).
2. **Fetch** — POSTs to Wavelog's `api/get_contacts_adif` with `fetchfromid`
   set to `state.last_qso_id`, returning only new QSOs as a raw ADIF string.
3. **Parse-ADIF** — hand-rolled regex parser splitting on `<EOR>` and matching
   `<FIELD:len>value` tags into PSCustomObjects. Records without a `CALL`
   field are dropped.
4. **Card selection (`Get-QslCard`)** — `card_assignments.json` maps uppercase
   callsigns to specific filenames in `cards/`. Cards listed there are
   excluded from the default random pool; unassigned callsigns get a random
   pick from `cards/` (falls back to the full set if the pool is empty or an
   assigned file is missing).
5. **Email (`Send-QslEmail`)** — builds an HTML body with QSO details
   (date/band/mode/RST/freq) and sends via `System.Net.Mail.SmtpClient` using
   `AlternateView` + `LinkedResource` for the inline image, plus a separate
   `Attachment` for the same card file. Honors `-DryRun` by logging instead
   of sending.
6. **State tracking** — max `APP_WAVELOG_LOGID` seen across the batch is
   written back to `state.json` after processing. If Wavelog doesn't export
   that ADIF field, state never advances and every run reprocesses all QSOs
   (noted as a version-dependent caveat in README).
7. **Skip rule** — QSOs without an `EMAIL` field (populated only via Wavelog
   callbook lookups) are logged and skipped, not retried.

## Config files (not committed with real secrets)

- `config.json` — Wavelog connection + station identity + SMTP credentials.
- `card_assignments.json` — per-callsign card filename overrides (`_comment*`
  keys are documentation only, ignored by the script).
- `state.json` — runtime-generated, tracks `last_qso_id`.
- `cards/` — QSL card images (jpg/jpeg/png).
- `logs/qsl-mailer-YYYY-MM.log` — monthly log files written by `Write-Log`.

**Do not read or edit `config.json` or `card_assignments.json`** — they hold
the user's live credentials and personal card mappings. For any config-shape
changes (new keys, format changes, etc.), update `config.example.json` /
`card_assignments.example.json` instead and tell the user to apply the change
to their real files manually.
