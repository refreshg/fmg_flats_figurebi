﻿# Adds realistic test data to staging: apartment products (m² uom, price per m²),
# test customers, and a ready demo quotation with a generated schedule.
$ErrorActionPreference = "Stop"
$base = "https://communapp-com-staging-37061251.dev.odoo.com"
$db = "communapp-com-staging-37061251"
$key = $env:FIGUREBI_STAGING_KEY  # staging admin password -> SECRETS.local.md

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
function Get-XmlId($module, $name) {
    return (Invoke-Odoo "ir.model.data" "check_object_reference" @($module, $name))[1]
}

# enable Disc.% column on order lines (standard setting)
$settingsId = [int](Invoke-Odoo "res.config.settings" "create" @(, @{group_discount_per_so_line = $true}))
Invoke-Odoo "res.config.settings" "execute" @(, @($settingsId)) | Out-Null
Write-Host "discount setting enabled"

# m² unit of measure
$m2Id = Get-XmlId "uom" "product_uom_square_meter"
Write-Host "m2 uom id=$m2Id"

# apartment products: code, name, area, price per m2
$apartments = @(
    @("APAR/I/512",  "ბინა I/512 (52.1 მ²)",  52.1, 1300.97),
    @("APAR/I/513",  "ბინა I/513 (45.3 მ²)",  45.3, 1350.00),
    @("APAR/I/812",  "ბინა I/812 (68.4 მ²)",  68.4, 1250.00),
    @("APAR/II/101", "ბინა II/101 (75.0 მ²)", 75.0, 1400.00),
    @("COM/I/1",     "კომერციული I/1 (120 მ²)", 120.0, 1800.00)
)
$prodIds = @{}
foreach ($a in $apartments) {
    $found = Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", $a[0])))
    if ($found.Count -gt 0) {
        $prodId = [int]$found[0]
        Invoke-Odoo "product.product" "write" @(@($prodId), @{name = $a[1]; list_price = $a[3]; uom_id = $m2Id; description_sale = "ჯამური ფართი: $($a[2]) მ²"}) | Out-Null
    } else {
        $prodId = [int](Invoke-Odoo "product.product" "create" @(, @{
            name = $a[1]; default_code = $a[0]; type = "service"
            list_price = $a[3]; uom_id = $m2Id
            description_sale = "ჯამური ფართი: $($a[2]) მ²"
            taxes_id = @(, @(6, 0, @()))
        }))
    }
    $prodIds[$a[0]] = $prodId
    Write-Host ("product {0} id={1}" -f $a[0], $prodId)
}

# test customers
$customers = @("გიორგი მაისურაძე (ტესტი)", "ნინო კაპანაძე (ტესტი)")
$partnerIds = @()
foreach ($c in $customers) {
    $found = Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", $c)))
    if ($found.Count -gt 0) { $partnerIds += [int]$found[0] } else {
        $partnerIds += [int](Invoke-Odoo "res.partner" "create" @(, @{name = $c; phone = "+995 555 000 000"}))
    }
}
Write-Host "customers: $($partnerIds -join ', ')"

# demo quotation: apartment 512, qty = area, 5% discount, installment params filled
$soVals = @{
    partner_id = $partnerIds[0]
    order_line = @(, @(0, 0, @{
        product_id = $prodIds["APAR/I/512"]
        product_uom_qty = 52.1
        price_unit = 1300.97
        discount = 5.0
        tax_ids = @(, @(6, 0, @()))
    }))
    x_payment_type = "installment"
    x_first_tranche_pct = 10.0
    x_schedule_pct = 10.0
    x_first_payment_date = "2026-09-15"
    x_schedule_start_date = "2026-10-15"
    x_schedule_interval = 1
    x_project_end_date = "2027-12-30"
}
$soId = [int](Invoke-Odoo "sale.order" "create" @(, $soVals))
$actionId = [int](Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
Invoke-Odoo "ir.actions.server" "run" @(, @($actionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$so = Invoke-Odoo "sale.order" "read" @(@($soId), @("name", "amount_total"))
Write-Host ("demo quotation: " + ($so | ConvertTo-Json -Depth 3))
$lines = Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $soId)), @("x_number", "x_date", "x_amount", "x_is_weekend")) @{order = "x_number"}
foreach ($l in $lines) {
    $wk = if ($l.x_is_weekend) { "  <-- WEEKEND" } else { "" }
    Write-Host ("{0}`t{1}`t{2}{3}" -f $l.x_number, $l.x_date, $l.x_amount, $wk)
}
Write-Host "TEST DATA DONE"
