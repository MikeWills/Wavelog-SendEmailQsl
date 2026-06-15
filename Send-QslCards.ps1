#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Polls Wavelog for new QSOs and sends QSL card emails to each contact.

.DESCRIPTION
    Uses Wavelog's api/get_contacts_adif endpoint (fetchfromid) to pull only
    new QSOs since the last run. Sends an HTML email with the QSL card both
    inline and as an attachment. Card selection: per-callsign assignment first,
    then random from the default pool.

    -DryRun preserves a pure preview: nothing is emailed and state.json is
    not updated, so a real run afterwards processes the same QSOs.

    -MarkCaughtUp fetches all pending QSOs, advances state.json to the
    latest one, and exits without sending any email or selecting cards.
    Use this on an existing logbook to start processing only new QSOs
    from this point forward.

.NOTES
    Requires: PowerShell 7+
    Config:   config.json (same directory as this script)
    Schedule: cron (see README.md)
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot/config.json",
    [switch]$DryRun,       # Print what would be sent, but don't actually send email or update state
    [switch]$MarkCaughtUp  # Advance state.json to the latest QSO without sending any emails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Logging ────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line
}

# ─── Load Config ────────────────────────────────────────────────────────────

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$script:LogFile = Join-Path $PSScriptRoot ("logs/qsl-mailer-" + (Get-Date -Format 'yyyy-MM') + ".log")

Write-Log "=== QSL Mailer started ==="

# ─── State: last fetched QSO ID ─────────────────────────────────────────────

$StateFile = Join-Path $PSScriptRoot "state.json"

if (Test-Path $StateFile) {
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
} else {
    $state = [PSCustomObject]@{ last_qso_id = 0 }
}

Write-Log "Fetching QSOs with ID > $($state.last_qso_id)"

# ─── Pull new QSOs from Wavelog ─────────────────────────────────────────────

$apiUrl  = "$($cfg.wavelog.url.TrimEnd('/'))/api/get_contacts_adif"
$payload = @{
    key        = $cfg.wavelog.api_key
    station_id = $cfg.wavelog.station_id
    fetchfromid = $state.last_qso_id
} | ConvertTo-Json

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method POST -Body $payload `
        -ContentType "application/json" -Headers @{ Accept = "application/json" }
} catch {
    Write-Log "Wavelog API call failed: $_" ERROR
    exit 1
}

if ($response.exported_qsos -eq 0) {
    Write-Log "No new QSOs found. Exiting."
    exit 0
}

Write-Log "Retrieved $($response.exported_qsos) new QSO(s)"

# ─── Parse ADIF ─────────────────────────────────────────────────────────────
# Wavelog returns an ADIF string inside response.adif

function Parse-ADIF {
    param([string]$Adif)

    $records = @()
    # Split on <EOR> (end of record)
    $rawRecords = $Adif -split '(?i)<eor>' | Where-Object { $_.Trim() -ne '' }

    foreach ($raw in $rawRecords) {
        $record = @{}
        # Each field: <FIELD_NAME:length>value  (or <FIELD_NAME:length:type>value)
        $matches = [regex]::Matches($raw, '<([^:>]+)(?::\d+(?::[^>]*)?)?>([^<]*)')
        foreach ($m in $matches) {
            $field = $m.Groups[1].Value.ToUpper()
            $value = $m.Groups[2].Value.Trim()
            if ($field -ne 'EOH') {
                $record[$field] = $value
            }
        }
        if ($record.Count -gt 0 -and $record.ContainsKey('CALL')) {
            $records += [PSCustomObject]$record
        }
    }
    return $records
}

$qsos = Parse-ADIF -Adif $response.adif

if ($qsos.Count -eq 0) {
    Write-Log "ADIF parsed but no valid QSO records found." WARN
    exit 0
}

# Track max QSO ID in this batch (Wavelog returns it as logid in ADIF)
$maxId = $state.last_qso_id

# ─── Catch-up mode: advance state without sending any email ─────────────────
if ($MarkCaughtUp) {
    foreach ($qso in $qsos) {
        if ($qso.PSObject.Properties['APP_WAVELOG_LOGID']) {
            $logId = [int]$qso.APP_WAVELOG_LOGID
            if ($logId -gt $maxId) { $maxId = $logId }
        }
    }

    if ($maxId -gt $state.last_qso_id) {
        $state.last_qso_id = $maxId
        $state | ConvertTo-Json | Set-Content $StateFile
        Write-Log "Marked as caught up: last_qso_id = $maxId ($($qsos.Count) existing QSO(s) skipped, no emails sent)"
    } else {
        Write-Log "No higher QSO ID found among $($qsos.Count) QSO(s); state unchanged."
    }

    exit 0
}

# ─── QSL Card Selection ──────────────────────────────────────────────────────
# Per-callsign assignments loaded from card_assignments.json
# Default pool = all images in the cards/ folder not otherwise reserved

$assignmentsFile = Join-Path $PSScriptRoot "card_assignments.json"
$assignments = @{}
if (Test-Path $assignmentsFile) {
    $rawAssignments = Get-Content $assignmentsFile -Raw | ConvertFrom-Json
    foreach ($prop in $rawAssignments.PSObject.Properties) {
        $assignments[$prop.Name.ToUpper()] = $prop.Value
    }
}

$cardsDir = Join-Path $PSScriptRoot "cards"
$allCards = Get-ChildItem -Path $cardsDir -Include *.jpg,*.jpeg,*.png -File

if ($allCards.Count -eq 0) {
    Write-Log "No QSL card images found in $cardsDir" ERROR
    exit 1
}

# Default pool: cards NOT listed as assigned to any specific callsign
$assignedFiles = $assignments.Values | ForEach-Object { $_.ToLower() }
$defaultPool = $allCards | Where-Object { $_.Name.ToLower() -notin $assignedFiles }

if ($defaultPool.Count -eq 0) {
    Write-Log "Default card pool is empty — all cards are callsign-assigned. Using full pool as fallback." WARN
    $defaultPool = $allCards
}

function Get-QslCard {
    param([string]$Callsign)

    $call = $Callsign.ToUpper()

    if ($assignments.ContainsKey($call)) {
        $cardPath = Join-Path $cardsDir $assignments[$call]
        if (Test-Path $cardPath) {
            Write-Log "  Using assigned card for $call : $($assignments[$call])"
            return Get-Item $cardPath
        } else {
            Write-Log "  Assigned card '$($assignments[$call])' not found for $call, falling back to pool." WARN
        }
    }

    # Pick random from default pool
    $card = $defaultPool | Get-Random
    Write-Log "  Using random default card for $call : $($card.Name)"
    return $card
}

# ─── Email Helpers ───────────────────────────────────────────────────────────

function Get-MimeType {
    param([string]$Extension)
    switch ($Extension.ToLower()) {
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.png'  { return 'image/png' }
        default { return 'application/octet-stream' }
    }
}

function Send-QslEmail {
    param(
        [string]$ToAddress,
        [string]$ToName,
        [string]$Callsign,
        [PSCustomObject]$Qso,
        [System.IO.FileInfo]$CardFile
    )

    $date    = if ($Qso.PSObject.Properties['QSO_DATE']) { $Qso.QSO_DATE } else { 'N/A' }
    $band    = if ($Qso.PSObject.Properties['BAND'])     { $Qso.BAND }     else { 'N/A' }
    $mode    = if ($Qso.PSObject.Properties['MODE'])     { $Qso.MODE }     else { 'N/A' }
    $rstSent = if ($Qso.PSObject.Properties['RST_SENT']) { $Qso.RST_SENT } else { '59' }
    $rstRcvd = if ($Qso.PSObject.Properties['RST_RCVD']) { $Qso.RST_RCVD } else { '59' }
    $freq    = if ($Qso.PSObject.Properties['FREQ'])     { $Qso.FREQ }     else { '' }

    # Format date YYYYMMDD -> YYYY-MM-DD
    if ($date -match '^\d{8}$') {
        $date = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
    }

    $cid     = "qslcard_$([System.Guid]::NewGuid().ToString('N'))"
    $mimeType = Get-MimeType $CardFile.Extension

    $subject = "$($cfg.station.callsign) QSL Card — $Callsign $date $band $mode"

    $freqLine = if ($freq) { "<tr><td><strong>Frequency:</strong></td><td>$freq MHz</td></tr>" } else { "" }

    $htmlBody = @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; color: #222; max-width: 640px; margin: auto;">
  <h2 style="color:#003366;">QSL Confirmation — 73 de $($cfg.station.callsign)</h2>
  <p>Hello $ToName,</p>
  <p>
    Thank you for the QSO! It was a pleasure to work you.
    Please find my QSL card confirming our contact below and attached.
  </p>

  <table style="border-collapse:collapse; margin-bottom:1em;">
    <tr><td><strong>Your Callsign:</strong></td><td>$Callsign</td></tr>
    <tr><td><strong>Date (UTC):</strong></td><td>$date</td></tr>
    <tr><td><strong>Band:</strong></td><td>$band</td></tr>
    <tr><td><strong>Mode:</strong></td><td>$mode</td></tr>
    <tr><td><strong>RST Sent:</strong></td><td>$rstSent</td></tr>
    <tr><td><strong>RST Rcvd:</strong></td><td>$rstRcvd</td></tr>
    $freqLine
  </table>

  <p><img src="cid:$cid" alt="QSL Card" style="max-width:100%; border:1px solid #ccc;"></p>

  <p style="margin-top:2em;">73 de $($cfg.station.callsign)<br>
  $($cfg.station.name)<br>
  $($cfg.station.location)</p>
</body>
</html>
"@

    if ($DryRun) {
        Write-Log "  [DRY RUN] Would send to: $ToAddress | Subject: $subject | Card: $($CardFile.Name)"
        return
    }

    # Send via SMTP
    $smtpClient = [System.Net.Mail.SmtpClient]::new($cfg.smtp.host, $cfg.smtp.port)
    $smtpClient.EnableSsl = $cfg.smtp.use_ssl

    if ($cfg.smtp.username -and $cfg.smtp.password) {
        $smtpClient.Credentials = [System.Net.NetworkCredential]::new(
            $cfg.smtp.username,
            $cfg.smtp.password
        )
    }

    # SmtpClient can't easily handle multipart/related+inline CID, so we use
    # AlternateView + LinkedResource which is the .NET-native way
    $linkedRes = [System.Net.Mail.LinkedResource]::new(
        $CardFile.FullName,
        $mimeType
    )
    $linkedRes.ContentId = $cid

    $htmlView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
        $htmlBody,
        [System.Text.Encoding]::UTF8,
        "text/html"
    )
    $htmlView.LinkedResources.Add($linkedRes)

    $mailMsg = [System.Net.Mail.MailMessage]::new()
    $mailMsg.From    = [System.Net.Mail.MailAddress]::new($cfg.smtp.from_address, $cfg.smtp.from_name)
    $mailMsg.To.Add([System.Net.Mail.MailAddress]::new($ToAddress, $ToName))
    if ($cfg.smtp.PSObject.Properties['reply_to'] -and $cfg.smtp.reply_to) {
        $mailMsg.ReplyToList.Add([System.Net.Mail.MailAddress]::new($cfg.smtp.reply_to))
    }
    $mailMsg.Subject = $subject
    $mailMsg.AlternateViews.Add($htmlView)

    # Attachment copy
    $attachment = [System.Net.Mail.Attachment]::new($CardFile.FullName, $mimeType)
    $attachment.Name = $CardFile.Name
    $mailMsg.Attachments.Add($attachment)

    $smtpClient.Send($mailMsg)
    $mailMsg.Dispose()
}

# ─── Process each QSO ───────────────────────────────────────────────────────

$sent = 0
$skipped = 0

foreach ($qso in $qsos) {
    $callsign = $qso.CALL

    # Track highest internal ID (Wavelog uses APP_WAVELOG_LOGID in ADIF)
    if ($qso.PSObject.Properties['APP_WAVELOG_LOGID']) {
        $logId = [int]$qso.APP_WAVELOG_LOGID
        if ($logId -gt $maxId) { $maxId = $logId }
    }

    # Email address: Wavelog stores it in EMAIL field (if callbook lookup enabled)
    $emailAddr = if ($qso.PSObject.Properties['EMAIL']) { $qso.EMAIL } else { '' }
    $contactName = if ($qso.PSObject.Properties['NAME']) { $qso.NAME } else { $callsign }

    if (-not $emailAddr) {
        Write-Log "  Skipping $callsign — no email address in QSO record" WARN
        $skipped++
        continue
    }

    Write-Log "Processing QSO: $callsign <$emailAddr>"

    $card = Get-QslCard -Callsign $callsign

    try {
        Send-QslEmail `
            -ToAddress  $emailAddr `
            -ToName     $contactName `
            -Callsign   $callsign `
            -Qso        $qso `
            -CardFile   $card
        Write-Log "  Sent QSL to $callsign <$emailAddr>"
        $sent++
    } catch {
        Write-Log "  Failed to send to $callsign <$emailAddr>: $_" ERROR
    }

    # Brief pause to avoid SMTP rate limiting
    Start-Sleep -Milliseconds 500
}

# ─── Persist State ───────────────────────────────────────────────────────────

if ($DryRun) {
    Write-Log "[DRY RUN] State not updated (would advance last_qso_id to $maxId)"
} elseif ($maxId -gt $state.last_qso_id) {
    $state.last_qso_id = $maxId
    $state | ConvertTo-Json | Set-Content $StateFile
    Write-Log "State updated: last_qso_id = $maxId"
}

Write-Log "Done. Sent: $sent | Skipped (no email): $skipped"
