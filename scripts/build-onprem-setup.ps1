﻿# Assembles setup-onprem.ps1: concatenates the proven staging deploy scripts in
# chronological order (replaying the exact history that produced the working
# staging), with test sections stripped and target/credentials parameterized.
$ErrorActionPreference = "Stop"
$scripts = "c:\Users\elene\OneDrive\Desktop\FIGUREBI კალკულატორი\scripts"
$out = "c:\Users\elene\OneDrive\Desktop\FIGUREBI კალკულატორი\setup-onprem.ps1"

# file -> cut marker (content from the marker onward is dropped); $null = keep all
$plan = [ordered]@{
    "deploy-jsonrpc.ps1"               = $null
    "add-test-data.ps1"                = $null
    "add-stale-warning.ps1"            = "# 4. e2e test"
    "add-pdf-report.ps1"               = "# 4. test:"
    "add-invoice-generation.ps1"       = "# 4. run it on the demo order"
    "update-quotation-email.ps1"       = "# 4. test-render"
    "add-weekend-guard-smartbutton.ps1" = "# --- 4. tests"
    "add-weekend-autofix.ps1"          = "# 5. e2e test"
    "add-invoice-state-guard.ps1"      = "# 3. test:"
    "add-manual-months.ps1"            = "# 5. tests"
    "add-schedule-end-date.ps1"        = "# 3. test on existing demo"
    "add-balance-column.ps1"           = "# 3. test on demo"
    "add-paired-percents.ps1"          = "# 3. sanity check"
    "rework-calculator-v2.ps1"         = $null
    "add-header-cards.ps1"             = "# 4. sanity"
    "add-periodicity.ps1"              = "# 5. test:"
    "add-discount-pct.ps1"             = "# 4. tests"
    "fix-discount-priority.ps1"        = "# tests: sequential edits"
    "add-bank-split.ps1"               = $null
    "add-final-date-sync.ps1"          = "# tests"
    "add-crm-lang-assign.ps1"          = "# 3. tests"
}

$header = @'
# ============================================================================
# FIGUREBI გადახდის კალკულატორი — სრული დაყენება on-premise სერვერზე
# გაშვება:  PowerShell-ში:  powershell -ExecutionPolicy Bypass -File .\setup-onprem.ps1
# სკრიპტი გაშვებისას გკითხავთ ადმინის ლოგინს/პაროლს. ხანგრძლივობა: ~3-5 წუთი.
# უსაფრთხოა ხელახლა გაშვება (idempotent - არსებულს აახლებს).
# ============================================================================
$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$global:ONPREM_LOGIN = Read-Host "Odoo ადმინის ლოგინი (Enter = admin)"
if (-not $global:ONPREM_LOGIN) { $global:ONPREM_LOGIN = "admin" }
$sec = Read-Host "Odoo ადმინის პაროლი" -AsSecureString
$global:ONPREM_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
Write-Host "სამიზნე: https://46.233.53.183:2223 / ბაზა: odoo / მომხმარებელი: $global:ONPREM_LOGIN"

# --- prerequisite: make sure required Odoo modules are installed -------------
function Invoke-PreRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "https://46.233.53.183:2223/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$preUid = Invoke-PreRaw "common" "authenticate" @("odoo", $global:ONPREM_LOGIN, $global:ONPREM_PASSWORD, @{})
if (-not $preUid) { throw "ავტორიზაცია ვერ მოხერხდა — შეამოწმეთ ლოგინი/პაროლი" }
Write-Host "ავტორიზაცია OK (uid=$preUid)"
foreach ($m in @("base_automation", "sale_management", "crm")) {
    $mods = @(Invoke-PreRaw "object" "execute_kw" @("odoo", $preUid, $global:ONPREM_PASSWORD, "ir.module.module", "search_read", @(, @(, @("name", "=", $m))), @{fields = @("state")}))
    if ($mods.Count -eq 0) { throw "მოდული $m ვერ მოიძებნა სერვერზე" }
    if ($mods[0].state -ne "installed") {
        Write-Host "ვაყენებ საჭირო მოდულს: $m ..."
        Invoke-PreRaw "object" "execute_kw" @("odoo", $preUid, $global:ONPREM_PASSWORD, "ir.module.module", "button_immediate_install", @(, @([int]$mods[0].id))) | Out-Null
        Write-Host "$m დაყენდა"
    } else { Write-Host "$m უკვე დგას" }
}

'@

$body = ""
foreach ($name in $plan.Keys) {
    $path = Join-Path $scripts $name
    $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($true))
    $marker = $plan[$name]
    if ($marker) {
        $idx = $text.IndexOf($marker)
        if ($idx -lt 0) { throw "marker not found in ${name}: $marker" }
        $text = $text.Substring(0, $idx)
    }
    # retarget
    $text = $text.Replace("communapp-com-staging-37061251.dev.odoo.com", "46.233.53.183:2223")
    $text = $text.Replace('$db = "communapp-com-staging-37061251"', '$db = "odoo"')
    $text = $text.Replace('$key = $env:FIGUREBI_STAGING_KEY  # staging admin password -> SECRETS.local.md', '$key = $global:ONPREM_PASSWORD')
    $text = $text.Replace('$login = "admin"', '$login = $global:ONPREM_LOGIN')
    $text = $text.Replace('"admin", $key', '$global:ONPREM_LOGIN, $key')
    $body += "`n`nWrite-Host ''`nWrite-Host '=================== $name ==================='`n" + $text
}

$footer = @'

Write-Host ""
Write-Host "============================================================"
Write-Host "  დაყენება დასრულდა! გახსენით Sales -> New Quotation და"
Write-Host "  ნახეთ ტაბი 'გადახდის კალკულატორი'."
Write-Host "============================================================"
'@

[System.IO.File]::WriteAllText($out, ($header + $body + $footer), [System.Text.UTF8Encoding]::new($true))
Write-Host "ASSEMBLED: $out ($((Get-Item $out).Length) bytes)"
