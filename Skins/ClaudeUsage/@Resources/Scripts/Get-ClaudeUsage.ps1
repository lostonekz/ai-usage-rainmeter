<#
.SYNOPSIS
    Fetches Claude.ai and Codex/ChatGPT usage data and writes it for the Rainmeter widget.

.DESCRIPTION
    Claude: reads the OAuth access token from Claude Code's credentials file and calls
    the Anthropic usage API. Uses the modern "limits" array (session / weekly_all /
    weekly_scoped) so the scoped-model row follows whatever model the plan actually
    meters, instead of the retired seven_day_sonnet bucket. Falls back to the legacy
    top-level objects if "limits" is missing.

    Codex: reads the ChatGPT OAuth token from Codex's auth.json and calls the usage
    endpoint for the 5-hour and 7-day windows. This endpoint is undocumented and may
    change without notice; if it does, the Codex rows degrade to "n/a" and the Claude
    rows keep working.

    Neither provider is allowed to break the other - each is fetched in its own
    try/catch and renders independently.

    Runs on both Windows PowerShell 5.1 and PowerShell 7.

.OUTPUTS
    Writes usage data to %APPDATA%\ClaudeUsage\usage.json
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$credentialsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$codexAuthPath   = Join-Path $env:USERPROFILE '.codex\auth.json'
$outputDir  = Join-Path $env:APPDATA 'ClaudeUsage'
$outputPath = Join-Path $outputDir 'usage.json'
$apiUrl      = 'https://api.anthropic.com/api/oauth/usage'
$codexApiUrl = 'https://chatgpt.com/backend-api/wham/usage'

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

# Builds one widget row from a percent + a reset time already normalised to UTC.
function New-Row {
    param($Percent, $ResetUtc, [string]$Label = '', $Share = $null, [bool]$Available = $true)

    $row = [PSCustomObject]@{
        label          = $Label
        percent        = 0
        share          = ''
        resetCountdown = '--'
        resetDate      = ''
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
# Isolated from the Claude fetch: any failure here returns an "error" block and
# the Claude rows still render.
function Get-CodexUsage {
    try {
        if (-not (Test-Path $codexAuthPath)) {
            return New-CodexBlock -Plan 'no auth' -Detail 'Codex auth.json not found - sign in with Codex once'
        }

        $auth = Get-Content -Path $codexAuthPath -Raw | ConvertFrom-Json
        $token = $auth.tokens.access_token
        if (-not $token) { return New-CodexBlock -Plan 'no token' -Detail 'No access token in Codex auth.json' }

        # The token is refreshed by Codex itself; we only read it. If it has
        # lapsed, say so rather than firing a request that will 401.
        try {
            $seg = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
            while ($seg.Length % 4) { $seg += '=' }
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) | ConvertFrom-Json
            $exp = ConvertFrom-UnixSeconds $claims.exp
            if ($exp -and $exp -lt [DateTime]::UtcNow) {
                return New-CodexBlock -Plan 'expired' -Detail 'Codex token expired - run Codex once to refresh it'
            }
        } catch {
            # Unreadable JWT is not fatal - let the request decide.
        }

        $headers = @{
            'Authorization'      = "Bearer $token"
            'chatgpt-account-id' = $auth.tokens.account_id
            'originator'         = 'codex_cli_rs'
            'User-Agent'         = 'codex_cli_rs/0.0.0'
        }
        $r = Invoke-RestMethod -Uri $codexApiUrl -Headers $headers -Method Get -TimeoutSec 20

        $plan = if ($r.plan_type) {
            $t = [string]$r.plan_type
            $t.Substring(0,1).ToUpper() + $t.Substring(1)
        } else { 'n/a' }

        $primary   = $r.rate_limit.primary_window
        $secondary = $r.rate_limit.secondary_window

        $fiveHour = New-Row -Percent $primary.used_percent   -ResetUtc (ConvertFrom-UnixSeconds $primary.reset_at)
        $sevenDay = New-Row -Percent $secondary.used_percent -ResetUtc (ConvertFrom-UnixSeconds $secondary.reset_at)

        return New-CodexBlock -Status 'ok' -Plan $plan -FiveHour $fiveHour -SevenDay $sevenDay

    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $label = switch ($code) {
            401 { 'auth failed' }
            403 { 'forbidden' }
            429 { 'rate limited' }
            0   { 'unreachable' }
            default { "HTTP $code" }
        }
        $detail = switch ($code) {
            401 { 'Codex token rejected - run Codex once to refresh it' }
            403 { 'Codex usage endpoint refused the request (it is undocumented and may have moved)' }
            429 { 'Codex API rate limited - it will retry on the next refresh' }
            0   { 'Could not reach the Codex API' }
            default { "Codex API returned HTTP $code" }
        }
        return New-CodexBlock -Plan $label -Detail $detail
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

    $credentialsRaw = Get-Content -Path $credentialsPath -Raw | ConvertFrom-Json
    $credentials = if ($credentialsRaw.claudeAiOauth) { $credentialsRaw.claudeAiOauth } else { $credentialsRaw }
    $claudePlan = Get-ClaudePlan -Credentials $credentials

    if (-not $credentials.accessToken) {
        Write-ErrorState -ErrorMessage "No access token found in credentials file" -Codex $codexBlock -Plan $claudePlan
        exit 1
    }

    if ($credentials.expiresAt) {
        $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        if ($epoch.AddMilliseconds([long]$credentials.expiresAt) -lt [DateTime]::UtcNow) {
            Write-ErrorState -ErrorMessage "OAuth token has expired. Please re-authenticate with Claude Code." -Codex $codexBlock -Plan $claudePlan
            exit 1
        }
    }

    $headers = @{
        'Authorization'  = "Bearer $($credentials.accessToken)"
        'anthropic-beta' = 'oauth-2025-04-20'
    }
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get

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
