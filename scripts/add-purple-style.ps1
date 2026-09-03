﻿# Makes auto-fixed (purple) schedule rows stand out: bold dark-purple text on a
# light purple background. CSS is stored as a public attachment and registered
# in the web.assets_backend bundle via ir.asset. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://communapp-com-staging-37061251.dev.odoo.com"
$db = "communapp-com-staging-37061251"
$key = $env:FIGUREBI_STAGING_KEY  # staging admin password -> SECRETS.local.md

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, "admin", $key, @{})
function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}

# 1. CSS attachment (public)
$css = @'
/* FIGUREBI: auto-fixed (purple) installment rows — bold dark purple on light purple bg */
div[name="x_installment_line_ids"] tr.text-primary td {
    background-color: #f0dcff !important;
    color: #6a1b9a !important;
    font-weight: 700;
}
/* keep weekend (red) rows readable and dominant over striping */
div[name="x_installment_line_ids"] tr.text-danger td {
    font-weight: 700;
}
'@
$cssB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($css))
$attIds = @(Invoke-Odoo "ir.attachment" "search" @(, @(, @("name", "=", "figurebi_schedule.css"))))
if ($attIds.Count -gt 0) {
    $attId = [int]$attIds[0]
    Invoke-Odoo "ir.attachment" "write" @(@($attId), @{datas = $cssB64; public = $true; mimetype = "text/css"}) | Out-Null
} else {
    $attId = [int](Invoke-Odoo "ir.attachment" "create" @(, @{
        name = "figurebi_schedule.css"; type = "binary"; datas = $cssB64
        mimetype = "text/css"; public = $true; res_model = "ir.ui.view"; res_id = 0
    }))
}
Write-Host "css attachment id=$attId"

# 2. register in the backend asset bundle
$path = "/web/content/$attId/figurebi_schedule.css"
$assetIds = @(Invoke-Odoo "ir.asset" "search" @(, @(, @("name", "=", "FIGUREBI schedule purple style"))))
if ($assetIds.Count -gt 0) {
    Invoke-Odoo "ir.asset" "write" @(@($assetIds[0]), @{path = $path; bundle = "web.assets_backend"; active = $true}) | Out-Null
    Write-Host "ir.asset updated (id=$($assetIds[0]))"
} else {
    $assetId = [int](Invoke-Odoo "ir.asset" "create" @(, @{
        name = "FIGUREBI schedule purple style"; bundle = "web.assets_backend"; path = $path
    }))
    Write-Host "ir.asset created (id=$assetId)"
}

# 3. verify the CSS is served
$authBody = @{jsonrpc = "2.0"; method = "call"; params = @{db = $db; login = "admin"; password = $key}} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$base/web/session/authenticate" -Method Post -ContentType "application/json" -Body $authBody -SessionVariable ws | Out-Null
$served = Invoke-WebRequest -Uri "$base$path" -WebSession $ws
$servedText = [System.Text.Encoding]::UTF8.GetString($served.Content)
if ($servedText -match "f0dcff") { Write-Host "CSS served OK ($($served.StatusCode), $($servedText.Length) chars)" } else { Write-Host "WARNING: served content unexpected" }
Write-Host "PURPLE STYLE DONE"
