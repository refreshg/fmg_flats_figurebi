﻿# Adds an enterable discount % that syncs both ways with the $ discount fields
# and the line's Disc.%: enter $ -> see %, enter % -> see $. Idempotent.
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

# 1. discount % field (stored, enterable)
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_discount_pct")) @{
    model_id = $saleModelId; name = "x_discount_pct"; state = "manual"
    field_description = "ფასდაკლება (%)"; ttype = "float"
} | Out-Null
Write-Host "pct field ok"

# 2. $ -> % automation (update existing action: also fills x_discount_pct)
$codeC = @'
# Discount entered in dollars (per m2 or total): translate to the line's Disc.%,
# mirror the other dollar field and show the resulting percent.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        gross = line.price_unit * line.product_uom_qty
        per_m2 = order.x_discount_per_m2 or 0.0
        total_d = order.x_discount_total or 0.0
        if per_m2 and abs(per_m2 * line.product_uom_qty - total_d) > 0.01:
            total_d = round(per_m2 * line.product_uom_qty, 2)
        elif total_d:
            per_m2 = round(total_d / line.product_uom_qty, 2)
        pct = round(total_d / gross * 100.0, 4) if gross else 0.0
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_total': total_d,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeC
} | Out-Null
Write-Host "dollar->pct action updated"

# 3. % -> $ automation (new)
$pctFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", "x_discount_pct"))))[0]
$autoD = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების %-ის სინქრონი")) @{
    name = "FIGUREBI: ფასდაკლების %-ის სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($pctFieldId))); active = $true
}
$codeD = @'
# Discount entered as a percent: write the line's Disc.% and fill both dollar fields.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        pct = order.x_discount_pct or 0.0
        if pct > 100:
            raise UserError("ფასდაკლება 100%-ს ვერ გადააჭარბებს (მინუსი = ფასნამატი).")
        gross = line.price_unit * line.product_uom_qty
        total_d = round(gross * pct / 100.0, 2)
        per_m2 = round(line.price_unit * pct / 100.0, 2)
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_total': total_d,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების %-ის სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების %-ის სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeD
    usage = "base_automation"; base_automation_id = $autoD
} | Out-Null
Write-Host "pct->dollar automation ok"

# 4. tests
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
}))
"T1: enter total $3389.03 -> pct should appear (~5)"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_total = 3389.03}) | Out-Null
(Invoke-Odoo "sale.order" "read" @(@($soId), @("x_discount_pct", "x_discount_per_m2", "x_discount_total", "amount_total"))) | ConvertTo-Json -Depth 3
"T2: enter pct 10 -> dollars should appear"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_pct = 10.0}) | Out-Null
(Invoke-Odoo "sale.order" "read" @(@($soId), @("x_discount_pct", "x_discount_per_m2", "x_discount_total", "amount_total"))) | ConvertTo-Json -Depth 3
Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
"cleanup done; DISCOUNT PCT DONE"
