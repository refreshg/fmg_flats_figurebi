﻿# When spread months / schedule start / periodicity change on an installment
# order, auto-set the final payment date to one interval AFTER the last
# installment (Excel-like: balloon is the next date in the sequence).
# Typing the date directly still works (that write does not retrigger).
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
function Get-FieldId($name) {
    return [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", $name))))[0]
}

$autoE = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ბოლო გადახდის თარიღის სინქრონი")) @{
    name = "FIGUREBI: ბოლო გადახდის თარიღის სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_schedule_months"), (Get-FieldId "x_schedule_start_date"), (Get-FieldId "x_periodicity")))); active = $true
}
$codeE = @'
# Spread params changed: place the final (balloon) payment one interval after
# the last installment. Direct edits of the date itself do not retrigger this.
if not env.context.get('figurebi_final_sync'):
    for order in records:
        if (order.x_payment_type or 'installment') != 'installment':
            continue
        months = int(order.x_schedule_months or 0)
        if months > 0 and order.x_schedule_start_date:
            interval = int(order.x_periodicity or 1)
            count = max(1, months // interval)
            new_date = order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=count * interval)
            if order.x_final_payment_date != new_date:
                order.with_context(figurebi_final_sync=True).write({'x_final_payment_date': new_date})
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ბოლო გადახდის თარიღის სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ბოლო გადახდის თარიღის სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeE
    usage = "base_automation"; base_automation_id = $autoE
} | Out-Null
Write-Host "automation ok (id=$autoE)"

# tests
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"; x_first_payment_date = "2026-09-02"
    x_schedule_start_date = "2026-09-02"; x_schedule_months = 10; x_periodicity = "1"
    x_project_end_date = "2027-12-30"
}))
$r = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_final_payment_date", "x_schedule_end_date"))
Write-Host "T1 10m: final=$($r.x_final_payment_date) (expect 2027-07-02), auto-end=$($r.x_schedule_end_date) (expect 2027-06-02)"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_schedule_months = 6}) | Out-Null
$r = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_final_payment_date", "x_schedule_end_date"))
Write-Host "T2 6m: final=$($r.x_final_payment_date) (expect 2027-03-02), auto-end=$($r.x_schedule_end_date) (expect 2027-02-02)"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_final_payment_date = "2027-04-15"}) | Out-Null
$r = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_final_payment_date"))
Write-Host "T3 manual date: final=$($r.x_final_payment_date) (expect 2027-04-15, stays)"
Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
Write-Host "cleanup done; FINAL DATE SYNC DONE"
