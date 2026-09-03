﻿# Adds x_area (m²) to products and an Automation Rule that sets the sale line
# quantity to the apartment's area when the product is selected. Idempotent.
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
    $found = Invoke-Odoo $model "search" @(, $domain)
    if ($found.Count -gt 0) {
        Invoke-Odoo $model "write" @(@($found[0]), $vals) | Out-Null
        return [int]$found[0]
    }
    return [int](Invoke-Odoo $model "create" @(, $vals))
}

# 1. x_area field on product.template
$tmplModelId = [int](Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "product.template"))))[0]
Ensure-Record "ir.model.fields" @(@("model_id", "=", $tmplModelId), @("name", "=", "x_area")) @{
    model_id = $tmplModelId; name = "x_area"; state = "manual"
    field_description = "ფართი (მ²)"; ttype = "float"
    help = "Total area in m2; auto-fills the quantity on sale order lines."
} | Out-Null
Write-Host "x_area field ok"

# 2. fill areas on the test apartments
$areas = @{ "APAR/I/512" = 52.1; "APAR/I/513" = 45.3; "APAR/I/812" = 68.4; "APAR/II/101" = 75.0; "COM/I/1" = 120.0 }
foreach ($code in $areas.Keys) {
    $prod = @(Invoke-Odoo "product.product" "search_read" @(@(, @("default_code", "=", $code)), @("product_tmpl_id")))
    if ($prod.Count -gt 0) {
        $tmplId = [int]$prod[0].product_tmpl_id[0]
        Invoke-Odoo "product.template" "write" @(@($tmplId), @{x_area = $areas[$code]}) | Out-Null
        Write-Host "area set: $code = $($areas[$code])"
    } else { Write-Host "SKIP (not found): $code" }
}

# 3. automation rule on sale.order.line
$lineModelId = [int](Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order.line"))))[0]
$productFieldId = [int](Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $lineModelId), @("name", "=", "product_id"))))[0]

$autoId = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფართის ავტომატური ჩასმა")) @{
    name = "FIGUREBI: ფართის ავტომატური ჩასმა"
    model_id = $lineModelId
    trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($productFieldId)))
    active = $true
}
Write-Host "automation id=$autoId"

$actionCode = @'
# When a product with a defined area (x_area) is chosen on a sale order line,
# set the line quantity to that area (qty in m2 = apartment area).
# NOTE: safe_eval forbids attribute assignment; item assignment is allowed.
for line in records:
    area = line.product_id.product_tmpl_id.x_area
    if area:
        line['product_uom_qty'] = area
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფართი -> რაოდენობა")) @{
    name = "FIGUREBI: ფართი -> რაოდენობა"
    model_id = $lineModelId; state = "code"; code = $actionCode
    usage = "base_automation"; base_automation_id = $autoId
} | Out-Null
Write-Host "automation action ok"

# 4. end-to-end test: create SO with default qty 1, expect 52.1 after create
$prodId = [int](Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int](Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId}))
}))
$line = Invoke-Odoo "sale.order.line" "search_read" @(@(, @("order_id", "=", $soId)), @("product_uom_qty", "price_unit", "price_subtotal"))
Write-Host ("TEST result: " + ($line | ConvertTo-Json -Depth 3))
Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
Write-Host "test SO removed"
Write-Host "AREA AUTOFILL DONE"
