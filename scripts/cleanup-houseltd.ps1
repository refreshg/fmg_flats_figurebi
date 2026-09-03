﻿# Removes EVERYTHING the calculator deploy added to the houseltd staging DB,
# restoring it to its initial state. (It was the wrong database.)
$ErrorActionPreference = "Stop"
$base = "https://houseltd-staging-36920288.dev.odoo.com"
$db = "houseltd-staging-36920288"
$key = $env:FIGUREBI_HOUSELTD_KEY  # server deleted; key kept in SECRETS.local.md

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error | ConvertTo-Json -Depth 10) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, "admin", $key, @{})
function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}
function Remove-ByDomain($model, $domain, $label) {
    $ids = Invoke-Odoo $model "search" @(, $domain)
    if ($ids.Count -gt 0) {
        Invoke-Odoo $model "unlink" @(, @($ids)) | Out-Null
        Write-Host "deleted $($ids.Count) $label"
    } else { Write-Host "no $label found" }
}

# 1. test sale orders (created by our tests)
Remove-ByDomain "sale.order" @(, @("name", "=", "S00026")) "test order S00026"

# 2. test products and partner
Remove-ByDomain "product.product" @(, @("default_code", "in", @("TEST/APAR/100", "APAR/I/512"))) "test products"
Remove-ByDomain "res.partner" @(, @("name", "=", "FIGUREBI TEST კლიენტი")) "test partner"

# 3. inherited view
Remove-ByDomain "ir.ui.view" @(, @("name", "=", "sale.order.form.figurebi.installment")) "view"

# 4. server action
Remove-ByDomain "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) "server action"

# 5. manual x_ fields on sale.order (o2m first, then the rest; ir.default cascades)
$saleModelId = [int](Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]
$xFields = @("x_installment_line_ids", "x_payment_type", "x_first_tranche_pct", "x_schedule_pct",
    "x_first_payment_date", "x_schedule_start_date", "x_schedule_interval", "x_project_end_date",
    "x_bank_rate", "x_bank_term_months", "x_first_tranche_amount", "x_schedule_amount",
    "x_final_balloon_amount", "x_bank_pmt_reference")
foreach ($f in $xFields) {
    Remove-ByDomain "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", $f), @("state", "=", "manual")) "field $f"
}

# 6. the manual model (cascades its fields, table, and access rules)
Remove-ByDomain "ir.model.access" @(, @("name", "=", "figurebi.installment.line.salesman")) "access rule"
Remove-ByDomain "ir.model" @(@("model", "=", "x_figurebi_installment_line"), @("state", "=", "manual")) "line model"

# 7. revert the discount-per-line setting we enabled
$settingsId = [int](Invoke-Odoo "res.config.settings" "create" @(, @{group_discount_per_so_line = $false}))
Invoke-Odoo "res.config.settings" "execute" @(, @($settingsId)) | Out-Null
Write-Host "discount setting reverted"

Write-Host "CLEANUP DONE"
