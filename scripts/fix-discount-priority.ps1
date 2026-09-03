﻿# Splits the $-discount sync into two automations so the field the user just
# edited always wins: per-m2 trigger -> per-m2 is master; total trigger ->
# total is master. (Percent already has its own automation.) Idempotent.
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

# C1: per-m2 changed -> per-m2 is master
$autoC1 = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონი")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_discount_per_m2")))); active = $true
}
$codeC1 = @'
# Per-m2 discount/markup changed: it is the master; recompute total, percent,
# and the line's Disc.%. Negative = markup.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        per_m2 = order.x_discount_per_m2 or 0.0
        total_d = round(per_m2 * line.product_uom_qty, 2)
        pct = round(per_m2 / line.price_unit * 100.0, 4)
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_total': total_d,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeC1
    usage = "base_automation"; base_automation_id = $autoC1
} | Out-Null
Write-Host "C1 (per-m2 master) ok"

# C2: total changed -> total is master
$autoC2 = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონი (სრული)")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონი (სრული)"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_discount_total")))); active = $true
}
$codeC2 = @'
# Total discount/markup changed: it is the master; recompute per-m2, percent,
# and the line's Disc.%. Negative = markup.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        gross = line.price_unit * line.product_uom_qty
        total_d = order.x_discount_total or 0.0
        per_m2 = round(total_d / line.product_uom_qty, 2)
        pct = round(total_d / gross * 100.0, 4) if gross else 0.0
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება (სრული)")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება (სრული)"; model_id = $saleModelId; state = "code"; code = $codeC2
    usage = "base_automation"; base_automation_id = $autoC2
} | Out-Null
Write-Host "C2 (total master) ok"

# tests: sequential edits, the edited field must always win
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
}))
function Show($label) {
    $r = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_discount_pct", "x_discount_per_m2", "x_discount_total", "amount_total"))
    Write-Host ("{0}: pct={1} per_m2={2} total={3} amount={4}" -f $label, $r.x_discount_pct, $r.x_discount_per_m2, $r.x_discount_total, $r.amount_total)
}
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_per_m2 = 65.05}) | Out-Null; Show "T1 per_m2=65.05"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_total = 6778.05}) | Out-Null; Show "T2 total=6778.05 (must win)"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_pct = -5.0}) | Out-Null; Show "T3 pct=-5 (markup, must win)"
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_discount_per_m2 = 0.0}) | Out-Null; Show "T4 per_m2=0 (reset)"
Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
Write-Host "cleanup done; DISCOUNT PRIORITY FIX DONE"
