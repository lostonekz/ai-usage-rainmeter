<#
.SYNOPSIS
    Fetches Claude.ai and Codex/ChatGPT usage data and writes it for the Rainmeter widget.

.DESCRIPTION
    Claude: reads the OAuth access token from Claude Code's credentials file and calls
    the Anthropic usage API. Uses the modern "limits" array (session / weekly_all /
    weekly_scoped) so the scoped-model row follows whatever model the plan actually
    meters, instead of the retired seven_day_sonnet bucket. Falls back to the legacy
    top-level objects if "limits" is missing.

    Codex: reads the 5-hour and 7-day windows out of Codex's own session logs. The
    CLI is metered against a limit bucket of its own ("codex"), which no usage
    endpoint reachable from here reports; what the CLI displays comes from a snapshot
    the server attaches to every turn, and Codex records that snapshot in its session
    log, so that is where it is read from. The numbers are therefore as fresh as the
    last Codex turn, and the plan badge carries their age.

    Neither provider is allowed to break the other - each is fetched in its own
    try/catch and renders independently.

    Runs on both Windows PowerShell 5.1 and PowerShell 7.

.OUTPUTS
    Writes usage data to %APPDATA%\ClaudeUsage\usage.json
#>

[CmdletBinding()]
param(
    # Renew the access token even when the stored one still looks valid. Only
    # useful for exercising the refresh path by hand.
    [switch]$ForceRefresh
)

$ErrorActionPreference = 'Stop'

$credentialsPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$codexAuthPath    = Join-Path $env:USERPROFILE '.codex\auth.json'
$codexSessionsDir = Join-Path $env:USERPROFILE '.codex\sessions'
$outputDir  = Join-Path $env:APPDATA 'ClaudeUsage'
$outputPath = Join-Path $outputDir 'usage.json'
$apiUrl      = 'https://api.anthropic.com/api/oauth/usage'
$tokenUrl    = 'https://platform.claude.com/v1/oauth/token'

# Claude Code's own public OAuth client id - the same one the CLI puts in its
# authorize URL. The refresh grant is rejected without it.
$oauthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'  # gitleaks:allow - public PKCE client id, printed in the CLI authorize URL

# The token endpoint answers 429 with an empty body to PowerShell's default
# user agent, whatever the grant is worth - a junk token gets the same 429,
# and any explicit agent gets a real answer. So send one.
$userAgent = 'ai-usage-rainmeter/1.0 (windows; powershell)'

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

function Write-UsageJson {
    param($Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $outputPath -Encoding UTF8
}

# 5.1 hands back a String here, 7 hands back a DateTime. Normalise both.
function ConvertTo-UtcTime {
    param($Value)
    if (-not $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    try {
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    } catch {
        return $null
    }
}

function ConvertFrom-UnixSeconds {
    param($Seconds)
    if ($null -eq $Seconds -or "$Seconds" -eq '') { return $null }
    try {
        $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        return $epoch.AddSeconds([double]$Seconds)
    } catch {
        return $null
    }
}

function Format-Stamp {
    param([DateTime]$Local)
    $dayNum = $Local.Day
    $ordinal = switch ($dayNum) {
        {$_ -in 1,21,31} { 'st' }
        {$_ -in 2,22} { 'nd' }
        {$_ -in 3,23} { 'rd' }
        default { 'th' }
    }
    return "[{0} {1}{2} {3}, {4}]" -f $Local.ToString('ddd'), $dayNum, $ordinal, $Local.ToString('MMM'), $Local.ToString('h:mmtt').ToLower()
}

function Format-Countdown {
    param([DateTime]$Utc)
    $diff = $Utc - [DateTime]::UtcNow
    if ($diff.TotalSeconds -le 0) { return 'now' }
    $days = [Math]::Floor($diff.TotalDays)
    if ($days -gt 0) { return "{0}d {1}h" -f $days, $diff.Hours }
    if ($diff.Hours -gt 0) { return "{0}h {1}m" -f $diff.Hours, $diff.Minutes }
    return "{0}m" -f $diff.Minutes
}

# How long ago a reading was taken. Used for the Codex numbers, which are a
# snapshot of the last turn rather than a live figure.
function Format-Age {
    param([DateTime]$Utc)
    $diff = [DateTime]::UtcNow - $Utc
    if ($diff.TotalSeconds -lt 0) { return 'just now' }
    if ($diff.TotalDays -ge 1) { return "{0}d {1}h ago" -f [int]$diff.TotalDays, $diff.Hours }
    if ($diff.TotalHours -ge 1) { return "{0}h {1}m ago" -f [int]$diff.TotalHours, $diff.Minutes }
    if ($diff.TotalMinutes -ge 1) { return "{0}m ago" -f [int]$diff.TotalMinutes }
    return 'just now'
}

# Builds one widget row from a percent + a reset time already normalised to UTC.
#
# resetDate must never come out empty. The skin stacks each row below the one
# before it with Y=...R, which measures from the previous meter's bottom edge,
# and the date is the last meter in a reset line - so a String meter with no
# text collapses to zero height and the next row is drawn on top of this one.
# NoResetDate is what stands in when there is no reset time to show.
function New-Row {
    param($Percent, $ResetUtc, [string]$Label = '', $Share = $null, [bool]$Available = $true,
          [string]$NoResetDate = '--')

    $row = [PSCustomObject]@{
        label          = $Label
        percent        = 0
        share          = ''
        resetCountdown = '--'
        resetDate      = $NoResetDate
        resetAt        = $null
        available      = $Available
    }

    if (-not $Available) {
        $row.resetCountdown = 'Not Metered'
        return $row
    }

    if ($null -ne $Percent) { $row.percent = [Math]::Round([double]$Percent, 1) }
    if ($null -ne $Share -and "$Share" -ne '') { $row.share = "{0}% of weekly" -f [int]$Share }

    if ($ResetUtc) {
        $row.resetAt = $ResetUtc.ToString('o')
        $row.resetDate = Format-Stamp $ResetUtc.ToLocalTime()
        $row.resetCountdown = Format-Countdown $ResetUtc
    }
    return $row
}

# The usage API carries no plan name, so the tier comes from the local
# credentials file. rateLimitTier holds the multiplier (default_claude_max_5x),
# which is more useful than subscriptionType's bare "max".
function Get-ClaudePlan {
    param($Credentials)
    if (-not $Credentials) { return '' }
    $tier = [string]$Credentials.rateLimitTier
    $sub  = [string]$Credentials.subscriptionType

    if ($tier -match '(?i)max_(\d+)x') { return "Max $($Matches[1])x" }
    if (-not $sub) { return '' }
    return $sub.Substring(0,1).ToUpper() + $sub.Substring(1)
}

# --- Token upkeep ----------------------------------------------------------
# The credentials file is only rewritten when the standalone CLI runs: the
# desktop app refreshes inside its own session, so the 8-hour access token on
# disk goes stale while the account is perfectly logged in. Asking the user to
# re-authenticate over that is wrong - the refresh token sitting right next to
# it is good for 28 days - so spend it the way Claude Code and the Stream Deck
# plugin do, and write the result back so every other reader of the file gets
# the fresh token too.

function Read-ClaudeCredentials {
    $raw   = Get-Content -Path $script:credentialsPath -Raw | ConvertFrom-Json
    $oauth = if ($raw.claudeAiOauth) { $raw.claudeAiOauth } else { $raw }
    return [PSCustomObject]@{ Raw = $raw; Oauth = $oauth }
}

# Half an hour of slack. The point is not just to avoid starting a call on a
# token that expires mid-flight: the token endpoint answers bursts with a 429,
# so the renewal needs a wide window of cycles to land one success in while the
# token on disk is still good.
function Test-ClaudeTokenExpired {
    param($Oauth, [int]$SkewMinutes = 30)
    if (-not $Oauth.expiresAt) { return $false }
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return ($epoch.AddMilliseconds([long]$Oauth.expiresAt) -lt [DateTime]::UtcNow.AddMinutes($SkewMinutes))
}

function New-ClaudeHeaders {
    param([string]$AccessToken)
    return @{
        'Authorization'  = "Bearer $AccessToken"
        'anthropic-beta' = 'oauth-2025-04-20'
    }
}

function Test-Unauthorized {
    param($ErrorRecord)
    if (-not $ErrorRecord.Exception.Response) { return $false }
    return ([int]$ErrorRecord.Exception.Response.StatusCode -eq 401)
}

# Returns the fresh access token. The file is swapped in with File.Replace so a
# concurrent reader never sees a half-written file, and the previous copy stays
# as .bak. The server may hand back a new refresh token; persisting that is the
# whole point, since the old one dies the moment it is rotated.
function Update-ClaudeCredentials {
    param($Raw, $Oauth)

    if (-not $Oauth.refreshToken) { throw 'No refresh token in the credentials file.' }

    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = [string]$Oauth.refreshToken
        client_id     = $script:oauthClientId
    } | ConvertTo-Json -Compress

    try {
            $resp = Invoke-RestMethod -Uri $script:tokenUrl -Method Post -ContentType 'application/json' `
            -Body $body -UserAgent $script:userAgent -TimeoutSec 20
    } catch {
        # 5.1 hides the response body inside the exception, and that body is
        # the only thing that says whether the grant was rejected or the call
        # never landed. Pull it out so the banner is diagnosable.
        $detail = ''
        if ($_.Exception.Response) {
            $detail = "HTTP $([int]$_.Exception.Response.StatusCode) "
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $detail += (ConvertTo-SafeMessage $reader.ReadToEnd())
                $reader.Close()
            } catch { }
        }
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "Refresh call failed: $detail"
    }
    if (-not $resp.access_token) { throw 'The refresh response carried no access token.' }

    $Oauth | Add-Member -NotePropertyName accessToken -NotePropertyValue ([string]$resp.access_token) -Force
    if ($resp.refresh_token) {
        $Oauth | Add-Member -NotePropertyName refreshToken -NotePropertyValue ([string]$resp.refresh_token) -Force
    }
    if ($resp.expires_in) {
        $expiresAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000 * [long]$resp.expires_in)
        $Oauth | Add-Member -NotePropertyName expiresAt -NotePropertyValue $expiresAt -Force
    }
    # The 28-day window is anchored to the login, not rolling: this comes back
    # still pointing at login + 28 days. Writing it keeps the field describing
    # the token actually on disk, for whoever reads it next.
    if ($resp.refresh_token_expires_in) {
        $rtExpiresAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000 * [long]$resp.refresh_token_expires_in)
        $Oauth | Add-Member -NotePropertyName refreshTokenExpiresAt -NotePropertyValue $rtExpiresAt -Force
    }

    # 5.1's ConvertTo-Json stops at depth 2, which would flatten the mcpOAuth
    # entries of every other server into strings. Keep the whole file intact.
    $json = $Raw | ConvertTo-Json -Depth 20
    $tmp  = "$script:credentialsPath.tmp"
    $bak  = "$script:credentialsPath.bak"

    # Node reads this file: a BOM would break JSON.parse.
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $bak) { Remove-Item -Path $bak -Force }
    [System.IO.File]::Replace($tmp, $script:credentialsPath, $bak)

    return [string]$Oauth.accessToken
}

function New-CodexBlock {
    param([string]$Status = 'error', [string]$Plan = 'n/a', $FiveHour = $null, $SevenDay = $null, [string]$Detail = '')
    if (-not $FiveHour) { $FiveHour = New-Row -Percent 0 -ResetUtc $null }
    if (-not $SevenDay) { $SevenDay = New-Row -Percent 0 -ResetUtc $null }
    return [PSCustomObject]@{ status = $Status; plan = $Plan; detail = $Detail; fiveHour = $FiveHour; sevenDay = $SevenDay }
}

# The banner is read back out of the JSON by a regex of the form "([^"]*)", so a
# quote or backslash in a message would truncate it. Flatten to one safe line.
function ConvertTo-SafeMessage {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text -replace '[\r\n\t]+', ' '
    $t = $t -replace '["\\]', "'"
    $t = $t -replace '\s{2,}', ' '
    $t = $t.Trim()
    if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + '...' }
    return $t
}

# --- Codex / ChatGPT -------------------------------------------------------
# The ChatGPT usage endpoint was the obvious source and it is the wrong one.
# It reports the generic account bucket, which CLI traffic never touches, so it
# answers a flat 0% however much Codex has been used - which is why these rows
# sat empty. The figures the CLI shows come from a "codex" bucket the server
# attaches to each turn's response, and Codex writes that snapshot into its
# session log. So the newest log is the source here. The cost is that the
# numbers are only as fresh as the last Codex turn; the plan badge says how old
# they are, and a window that has since rolled over reads as empty.
#
# Sessions run to tens of megabytes, so only the tail of each is read. A
# snapshot rides along with every turn, so the last couple of megabytes hold
# one for any session that got as far as a single response.
function Read-CodexSnapshot {
    param($File, [int]$TailBytes = 2097152)

    $text = $null
    try {
        # Codex may hold the live session open, so share the write handle.
        $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $seeked = $stream.Length -gt $TailBytes
            if ($seeked) { $stream.Position = $stream.Length - $TailBytes }
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } catch {
        return $null
    }

    # One JSON event per line. Seeking into the middle of the file lands
    # mid-line, so that first fragment is skipped rather than parsed.
    $lines = $text -split "`n"
    $floor = if ($seeked) { 1 } else { 0 }

    for ($i = $lines.Count - 1; $i -ge $floor; $i--) {
        if ($lines[$i] -notmatch '"rate_limits"') { continue }
        try { $ev = $lines[$i] | ConvertFrom-Json } catch { continue }

        $limits = $ev.payload.rate_limits
        if (-not $limits) { continue }
        # Other buckets may show up here; only the CLI's own one is wanted.
        if ($limits.limit_id -and $limits.limit_id -ne 'codex') { continue }

        $asOf = ConvertTo-UtcTime $ev.timestamp
        if (-not $asOf) { continue }
        return [PSCustomObject]@{ Limits = $limits; AsOf = $asOf }
    }
    return $null
}

# Newest session first, since a session can be abandoned before its first turn
# and so carry no snapshot at all.
function Get-CodexSnapshot {
    $files = Get-ChildItem -Path $script:codexSessionsDir -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like '*.jsonl' } |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 5

    foreach ($file in $files) {
        $snap = Read-CodexSnapshot -File $file
        if ($snap) { return $snap }
    }
    return $null
}

# A window whose reset has already passed rolled over without a newer snapshot
# being written, which means no Codex turn has been spent in the current one.
# So it reads as 0% with no countdown, because an untouched sliding window has
# no boundary to count down to yet - and says so in place of the reset stamp,
# which also keeps the line its full height. See New-Row.
function New-CodexRow {
    param($Window)
    if (-not $Window) { return New-Row -Percent 0 -ResetUtc $null }

    $resetUtc = ConvertFrom-UnixSeconds $Window.resets_at
    if ($resetUtc -and $resetUtc -lt [DateTime]::UtcNow) {
        return New-Row -Percent 0 -ResetUtc $null -NoResetDate '(window empty)'
    }
    return New-Row -Percent $Window.used_percent -ResetUtc $resetUtc
}

# Isolated from the Claude fetch: any failure here returns an "error" block and
# the Claude rows still render.
function Get-CodexUsage {
    try {
        if (-not (Test-Path $codexSessionsDir)) {
            $detail = if (Test-Path $codexAuthPath) {
                'No Codex session history yet - run Codex once'
            } else {
                'Codex not set up here - sign in with Codex once'
            }
            return New-CodexBlock -Plan 'no data' -Detail $detail
        }

        $snap = Get-CodexSnapshot
        if (-not $snap) {
            return New-CodexBlock -Plan 'no data' -Detail 'No usage snapshot in the recent Codex sessions - run Codex once'
        }

        $limits = $snap.Limits
        $plan = if ($limits.plan_type) {
            $t = [string]$limits.plan_type
            $t.Substring(0,1).ToUpper() + $t.Substring(1)
        } else { 'n/a' }

        # These are a reading, not a live figure, so the badge carries its age
        # once it is old enough to matter.
        $age = Format-Age $snap.AsOf
        if ($age -ne 'just now') { $plan = "$plan ($age)" }

        $fiveHour = New-CodexRow -Window $limits.primary
        $sevenDay = New-CodexRow -Window $limits.secondary

        return New-CodexBlock -Status 'ok' -Plan $plan -FiveHour $fiveHour -SevenDay $sevenDay

    } catch {
        return New-CodexBlock -Plan 'error' -Detail ("Could not read Codex usage: " + (ConvertTo-SafeMessage $_.Exception.Message))
    }
}

# Rolls both providers into one dot colour and one banner line.
#   ok       - both answered
#   degraded - one of the two is down, the other still has fresh numbers
#   error    - neither answered
function Get-OverallState {
    param([string]$ClaudeError = '', $Codex)

    $claudeBad = -not [string]::IsNullOrEmpty($ClaudeError)
    $codexBad  = ($null -eq $Codex) -or ($Codex.status -ne 'ok')

    $parts = @()
    if ($claudeBad) { $parts += "Claude: " + (ConvertTo-SafeMessage $ClaudeError) }
    if ($codexBad) {
        $d = if ($Codex -and $Codex.detail) { $Codex.detail } else { 'Codex usage unavailable' }
        $parts += "Codex: " + (ConvertTo-SafeMessage $d)
    }

    $overall = if ($claudeBad -and $codexBad) { 'error' }
               elseif ($claudeBad -or $codexBad) { 'degraded' }
               else { 'ok' }

    return [PSCustomObject]@{ overall = $overall; message = ($parts -join '    ') }
}

function Write-ErrorState {
    param([string]$ErrorMessage, $Codex = $null, [string]$Plan = '')
    if (-not $Codex) { $Codex = New-CodexBlock -Detail 'Codex usage unavailable' }
    $st = Get-OverallState -ClaudeError $ErrorMessage -Codex $Codex
    $errorData = [PSCustomObject]@{
        status        = 'error'
        fiveHour      = (New-Row -Percent 0 -ResetUtc $null)
        sevenDay      = (New-Row -Percent 0 -ResetUtc $null)
        scoped        = (New-Row -Percent 0 -ResetUtc $null -Label 'Scoped' -Available $false)
        breakdown     = ''
        codex         = $Codex
        lastUpdated   = (Format-Stamp ([DateTime]::Now))
        claudePlan    = $Plan
        overall       = $st.overall
        statusMessage = $st.message
        error         = $ErrorMessage
    }
    Write-UsageJson -Data $errorData
    Write-Warning $ErrorMessage
}

# Fetched first so it is available even if the Claude call bails out early.
$codexBlock = Get-CodexUsage

# Set as soon as the credentials parse, so the error paths can still show the tier.
$claudePlan = ''

try {
    if (-not (Test-Path $credentialsPath)) {
        Write-ErrorState -ErrorMessage "Credentials file not found at $credentialsPath" -Codex $codexBlock
        exit 1
    }

    $stored      = Read-ClaudeCredentials
    $credentials = $stored.Oauth
    $claudePlan  = Get-ClaudePlan -Credentials $credentials

    if (-not $credentials.accessToken) {
        Write-ErrorState -ErrorMessage "No access token found in credentials file" -Codex $codexBlock -Plan $claudePlan
        exit 1
    }

    $accessToken = [string]$credentials.accessToken

    if ($ForceRefresh -or (Test-ClaudeTokenExpired -Oauth $credentials)) {
        try {
            $accessToken = Update-ClaudeCredentials -Raw $stored.Raw -Oauth $credentials
            Write-Verbose 'Access token refreshed and written back to the credentials file.'
        } catch {
            # The CLI may have refreshed - and rotated - the grant between our
            # read and this call, so look again before declaring it dead.
            $refreshError = $_.Exception.Message
            $again = Read-ClaudeCredentials
            if ($again.Oauth.accessToken -and -not (Test-ClaudeTokenExpired -Oauth $again.Oauth)) {
                Write-Warning "Token refresh failed, using the token still on disk. $refreshError"
                $accessToken = [string]$again.Oauth.accessToken
            } else {
                if ($refreshError -match '429') {
                    # Throttled, not logged out. The widget runs again in a
                    # minute or two, so never send the user to a login prompt
                    # over this one.
                    $hint = "Token refresh throttled by the server. Retrying on the next cycle."
                } else {
                    $hint = "Token refresh failed ($refreshError) Log in again with: claude.cmd auth login"
                }
                Write-ErrorState -ErrorMessage $hint -Codex $codexBlock -Plan $claudePlan
                exit 1
            }
        }
    }

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers (New-ClaudeHeaders $accessToken) -Method Get
    } catch {
        if (-not (Test-Unauthorized $_)) { throw }
        # A 401 on a token that still looked valid means it was revoked or
        # rotated elsewhere. Refresh once and retry before giving up.
        $again       = Read-ClaudeCredentials
        $accessToken = Update-ClaudeCredentials -Raw $again.Raw -Oauth $again.Oauth
        $response    = Invoke-RestMethod -Uri $apiUrl -Headers (New-ClaudeHeaders $accessToken) -Method Get
    }

    # --- Session + weekly rows: prefer the limits array, fall back to legacy buckets ---
    $limits = @($response.limits)
    $session   = $limits | Where-Object { $_.kind -eq 'session' }    | Select-Object -First 1
    $weeklyAll = $limits | Where-Object { $_.kind -eq 'weekly_all' } | Select-Object -First 1

    if ($session) {
        $fiveHourRow = New-Row -Percent $session.percent -ResetUtc (ConvertTo-UtcTime $session.resets_at)
    } else {
        $fiveHourRow = New-Row -Percent $response.five_hour.utilization -ResetUtc (ConvertTo-UtcTime $response.five_hour.resets_at)
    }

    if ($weeklyAll) {
        $sevenDayRow = New-Row -Percent $weeklyAll.percent -ResetUtc (ConvertTo-UtcTime $weeklyAll.resets_at)
    } else {
        $sevenDayRow = New-Row -Percent $response.seven_day.utilization -ResetUtc (ConvertTo-UtcTime $response.seven_day.resets_at)
    }

    # --- Scoped model row: whichever model the plan currently meters separately ---
    $scopedRow = New-Row -Percent 0 -ResetUtc $null -Label 'Scoped' -Available $false

    $scopedIndex = -1
    for ($i = 0; $i -lt $limits.Count; $i++) {
        if ($limits[$i].kind -eq 'weekly_scoped') { $scopedIndex = $i; break }
    }

    if ($scopedIndex -ge 0) {
        $scoped = $limits[$scopedIndex]
        $modelName = $scoped.scope.model.display_name
        if (-not $modelName) { $modelName = 'Scoped' }

        $shareRow = $response.weekly_scoped_shares | Where-Object { $_.limit_index -eq $scopedIndex } | Select-Object -First 1
        $share = if ($shareRow) { $shareRow.allowance_percent_of_weekly } else { $null }

        $scopedRow = New-Row -Percent $scoped.percent -ResetUtc (ConvertTo-UtcTime $scoped.resets_at) -Label $modelName -Share $share
    }

    # --- Where the weekly allowance actually went ---
    $breakdown = ''
    if ($response.seven_day_breakdown.rows) {
        $parts = $response.seven_day_breakdown.rows |
                 Where-Object { [double]$_.percent -gt 0 } |
                 Sort-Object { [double]$_.percent } -Descending |
                 ForEach-Object { "{0} {1}%" -f $_.display_name, [int]$_.percent }
        $breakdown = ($parts -join '  |  ')
    }

    $st = Get-OverallState -ClaudeError '' -Codex $codexBlock

    $usageData = [PSCustomObject]@{
        status        = 'ok'
        fiveHour      = $fiveHourRow
        sevenDay      = $sevenDayRow
        scoped        = $scopedRow
        breakdown     = $breakdown
        codex         = $codexBlock
        lastUpdated   = (Format-Stamp ([DateTime]::Now))
        claudePlan    = $claudePlan
        overall       = $st.overall
        statusMessage = $st.message
        error         = $null
    }

    Write-UsageJson -Data $usageData
    Write-Verbose "Usage data written to $outputPath"

} catch {
    $errorMsg = $_.Exception.Message
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        switch ($statusCode) {
            401 { $errorMsg = "Authentication failed. Token may be invalid or expired." }
            403 { $errorMsg = "Access forbidden. Check OAuth permissions." }
            429 { $errorMsg = "Rate limited. Please wait before retrying." }
            default { $errorMsg = "API error: $statusCode - $errorMsg" }
        }
    }
    Write-ErrorState -ErrorMessage $errorMsg -Codex $codexBlock -Plan $claudePlan
    exit 1
}
