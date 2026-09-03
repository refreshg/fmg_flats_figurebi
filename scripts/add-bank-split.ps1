﻿# Splits the bank_loan type Excel-style: co-participation (client's own money,
# reuses the first-tranche $/% synced fields) + loan amount (bank transfer) on
# its own date. Adds bank-only cards, updates generation + PMT + stale
# signature (both places). Idempotent.
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
function Ensure-Record($model, $domain, $vals) {
    $found = @(Invoke-Odoo $model "search" @(, $domain))
    if ($found.Count -gt 0) {
        Invoke-Odoo $model "write" @(@($found[0]), $vals) | Out-Null
        return [int]$found[0]
    }
    return [int](Invoke-Odoo $model "create" @(, $vals))
}

$saleModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]

# 1. new fields
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_transfer_date")) @{
    model_id = $saleModelId; name = "x_bank_transfer_date"; state = "manual"
    field_description = "სესხის ჩარიცხვის თარიღი"; ttype = "date"
    help = "Empty = same day as the co-participation payment."
} | Out-Null
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_loan_amount")) @{
    model_id = $saleModelId; name = "x_bank_loan_amount"; state = "manual"
    field_description = "სესხის თანხა"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_amount,x_payment_type"
    compute = "for r in self:`n    r['x_bank_loan_amount'] = round((r.amount_total or 0.0) - (r.x_first_tranche_amount or 0.0), 2) if (r.x_payment_type or '') == 'bank_loan' else 0.0"
} | Out-Null
Write-Host "fields ok"

# 2. PMT: bank_loan -> loan amount; installment -> balloon amount
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_pmt_reference")) @{
    model_id = $saleModelId; name = "x_bank_pmt_reference"; state = "manual"
    field_description = "საბანკო შენატანი (საცნობარო)"; ttype = "float"; store = $false
    depends = "amount_total,x_payment_type,x_first_tranche_amount,x_final_balloon_amount,x_bank_rate,x_bank_term_months"
    compute = "for r in self:`n    total = r.amount_total or 0.0`n    if (r.x_payment_type or '') == 'bank_loan':`n        p = total - (r.x_first_tranche_amount or 0.0)`n    else:`n        p = r.x_final_balloon_amount or 0.0`n    m = r.x_bank_term_months or 0`n    rate = (r.x_bank_rate or 0.0) / 100.0 / 12.0`n    if p <= 0 or m <= 0:`n        r['x_bank_pmt_reference'] = 0.0`n    elif rate:`n        r['x_bank_pmt_reference'] = round(p * rate / (1 - (1 + rate) ** -m), 2)`n    else:`n        r['x_bank_pmt_reference'] = round(p / m, 2)"
} | Out-Null
Write-Host "PMT compute updated"

Write-Host "BANK SPLIT PART 1 DONE (fields+PMT); view+generation patched via add-periodicity.ps1"
