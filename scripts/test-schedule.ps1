﻿# End-to-end test of the installment calculator on staging via JSON-RPC.
# Creates a test SO (70,000; no taxes), runs the schedule server action for the
# Excel reference case + edge cases, prints the generated schedules.
$ErrorActionPreference = "Stop"
$base = "https://houseltd-staging-36920288.dev.odoo.com"
$db = "houseltd-staging-36920288"
$key = $env:FIGUREBI_HOUSELTD_KEY  # server deleted; key kept in SECRETS.local.md

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") {
        throw ("Odoo error: " + ($r.error | ConvertTo-Json -Depth 10))
    }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, "admin", $key, @{})
function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}

$actionId = [int](Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]

# test product (per-unit price = full apartment price, no variants needed for test)
$prodTmplId = Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "TEST/APAR/100")))
if ($prodTmplId.Count -gt 0) { $prodId = [int]$prodTmplId[0] } else {
    $prodId = [int](Invoke-Odoo "product.product" "create" @(, @{name = "TEST ბინა 100"; default_code = "TEST/APAR/100"; type = "service"; list_price = 70000}))
}
$partnerIds = Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "FIGUREBI TEST კლიენტი")))
if ($partnerIds.Count -gt 0) { $partnerId = [int]$partnerIds[0] } else {
    $partnerId = [int](Invoke-Odoo "res.partner" "create" @(, @{name = "FIGUREBI TEST კლიენტი"}))
}

function New-TestOrder($vals) {
    $soVals = @{
        partner_id = $partnerId
        order_line = @(, @(0, 0, @{product_id = $prodId; product_uom_qty = 1; price_unit = 70000; tax_ids = @(, @(6, 0, @()))}))
    }
    foreach ($k in $vals.Keys) { $soVals[$k] = $vals[$k] }
    return [int](Invoke-Odoo "sale.order" "create" @(, $soVals))
}

function Run-AndPrint($label, $soId) {
    Invoke-Odoo "ir.actions.server" "run" @(, @($actionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
    $lines = Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $soId)), @("x_number", "x_date", "x_amount", "x_is_weekend")) @{order = "x_number"}
    Write-Host "=== $label (SO $soId) ==="
    $sum = 0
    foreach ($l in $lines) {
        $sum += $l.x_amount
        $wk = if ($l.x_is_weekend) { "  <-- WEEKEND" } else { "" }
        Write-Host ("{0}`t{1}`t{2}{3}" -f $l.x_number, $l.x_date, $l.x_amount, $wk)
    }
    Write-Host "SUM = $sum"
}

# Case 1: Excel reference — 10% + 10%, monthly, balloon 80%
$so1 = New-TestOrder @{
    x_payment_type = "installment"; x_first_tranche_pct = 10.0; x_schedule_pct = 10.0
    x_first_payment_date = "2026-07-10"; x_schedule_start_date = "2026-08-10"
    x_schedule_interval = 1; x_project_end_date = "2026-12-30"
}
Run-AndPrint "Case1: Excel 10+10 balloon" $so1

# Case 2: 20% + 80%, no balloon
$so2 = New-TestOrder @{
    x_payment_type = "installment"; x_first_tranche_pct = 20.0; x_schedule_pct = 80.0
    x_first_payment_date = "2026-07-10"; x_schedule_start_date = "2026-08-10"
    x_schedule_interval = 1; x_project_end_date = "2026-12-30"
}
Run-AndPrint "Case2: 20+80 no balloon" $so2

# Case 3: full payment
$so3 = New-TestOrder @{ x_payment_type = "full_payment"; x_first_payment_date = "2026-07-10" }
Run-AndPrint "Case3: full payment" $so3

# Case 4: bank loan
$so4 = New-TestOrder @{ x_payment_type = "bank_loan"; x_first_payment_date = "2026-07-10" }
Run-AndPrint "Case4: bank loan" $so4

# computed fields check on case 1
$c = Invoke-Odoo "sale.order" "read" @(@($so1), @("amount_total", "x_first_tranche_amount", "x_schedule_amount", "x_final_balloon_amount", "x_bank_pmt_reference"))
Write-Host ("computed: " + ($c | ConvertTo-Json -Depth 5))
