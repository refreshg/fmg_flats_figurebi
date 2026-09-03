﻿# E2E tests for the v2 calculator: %<->$ sync, $ discount, manual final date.
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

$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$genActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]

$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"
    x_first_payment_date = "2026-09-01"; x_schedule_start_date = "2026-09-15"
    x_schedule_interval = 1; x_project_end_date = "2027-09-30"
}))
function Read-SO($fields) { return Invoke-Odoo "sale.order" "read" @(@($soId), $fields) }

"T1: defaults + %->$ sync on create"
$r = Read-SO @("amount_total", "x_first_tranche_pct", "x_first_tranche_amount", "x_final_balloon_pct", "x_final_balloon_amount", "x_schedule_pct", "x_schedule_amount")
$r | ConvertTo-Json -Depth 3

"T2: write first amount 10000 -> pct should become ~14.75"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_first_tranche_amount = 10000.0}) | Out-Null
$r = Read-SO @("x_first_tranche_pct", "x_first_tranche_amount", "x_schedule_pct", "x_schedule_amount")
$r | ConvertTo-Json -Depth 3

"T3: discount total 3389.03 -> line Disc% ~5, total 64391.51, amounts refreshed by pct"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_total = 3389.03}) | Out-Null
$line = @(Invoke-Odoo "sale.order.line" "search_read" @(@(, @("order_id", "=", $soId)), @("discount", "price_total")))[0]
"line disc=$($line.discount) line total=$($line.price_total)"
$r = Read-SO @("amount_total", "x_discount_per_m2", "x_first_tranche_pct", "x_first_tranche_amount", "x_final_balloon_pct", "x_final_balloon_amount")
$r | ConvertTo-Json -Depth 3

"T4: set balloon 80% + manual final date, generate"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_first_tranche_pct = 10.0; x_final_balloon_pct = 80.0; x_final_payment_date = "2027-12-30"}) | Out-Null
Invoke-Odoo "ir.actions.server" "run" @(, @($genActionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$lines = @(Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $soId)), @("x_number", "x_date", "x_amount", "x_balance")) @{order = "x_number"})
$sum = 0
foreach ($l in $lines) { $sum += $l.x_amount; "{0}`t{1}`t{2}`t{3}" -f $l.x_number, $l.x_date, $l.x_amount, $l.x_balance }
"rows=$($lines.Count) sum=$sum"

"T5: final date earlier than last installment -> must error"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_final_payment_date = "2026-10-01"}) | Out-Null
try {
    Invoke-Odoo "ir.actions.server" "run" @(, @($genActionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
    "TEST FAIL: early final date NOT blocked!"
} catch { "early final date blocked OK: $($_.Exception.Message)" }

Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
"cleanup done; ALL TESTS FINISHED"
