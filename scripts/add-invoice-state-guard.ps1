﻿# Restricts invoice generation to CONFIRMED sales orders: the button is hidden
# on quotations and the server action refuses to run until state == 'sale'.
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

# 1. invoice action: require confirmed order (full canonical code)
$invActionCode = @'
# Creates one draft customer invoice per installment line: due date = the line's
# date, amount = the line's amount (tax-free, matches the schedule exactly).
# Requires a CONFIRMED sales order and a schedule without weekend (red) dates.
for order in records:
    if order.state != 'sale':
        raise UserError("ინვოისების გენერაცია მხოლოდ დადასტურებულ შეკვეთაზეა შესაძლებელი — ჯერ დაადასტურეთ (Confirm) შეთავაზება.")
    lines = order.x_installment_line_ids.sorted(key=lambda l: l.x_number)
    if not lines:
        raise UserError("ჯერ დააგენერირეთ განვადების გრაფიკი.")
    bad = lines.filtered(lambda l: l.x_is_weekend)
    if bad:
        raise UserError("გრაფიკში შაბათ-კვირის (წითელი) თარიღებია: %s. ჯერ ხელით შეასწორეთ და მერე გამოწერეთ ინვოისები." % ', '.join([str(d) for d in bad.mapped('x_date')]))
    existing = env['account.move'].search_count([
        ('invoice_origin', '=', order.name),
        ('move_type', '=', 'out_invoice'),
        ('state', '!=', 'cancel'),
    ])
    if existing:
        raise UserError("ამ შეკვეთაზე ინვოისები უკვე არსებობს (%s ცალი). ჯერ გააუქმეთ/წაშალეთ ისინი Accounting-ში." % existing)
    product = env['product.product'].search([('default_code', '=', 'INSTALLMENT-FEE')], limit=1)
    if not product:
        raise UserError("ვერ მოიძებნა პროდუქტი INSTALLMENT-FEE — მიმართეთ ადმინისტრატორს.")
    total_count = len(lines)
    for line in lines:
        env['account.move'].create({
            'move_type': 'out_invoice',
            'partner_id': order.partner_id.id,
            'currency_id': order.currency_id.id,
            'invoice_origin': order.name,
            'invoice_date_due': line.x_date,
            'invoice_payment_term_id': False,
            'invoice_user_id': order.user_id.id,
            'invoice_line_ids': [(0, 0, {
                'product_id': product.id,
                'name': "განვადების შენატანი %s/%s — %s" % (line.x_number, total_count, order.name),
                'quantity': 1,
                'price_unit': line.x_amount,
                'tax_ids': [(6, 0, [])],
            })],
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ინვოისების გენერაცია")) @{
    name = "FIGUREBI: ინვოისების გენერაცია"; model_id = $saleModelId; state = "code"; code = $invActionCode
} | Out-Null
Write-Host "invoice action updated with state guard"

# 2. view v6: invoice button hidden until the order is confirmed
$genActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
$invActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: ინვოისების გენერაცია"))))[0]
$fixActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: შაბ-კვ თარიღების გასწორება"))))[0]
$statActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: განვადების ინვოისების ნახვა"))))[0]
$arch = @"
<data>
  <xpath expr="//div[@name='button_box']" position="inside">
    <button class="oe_stat_button" icon="fa-list-ol" name="$statActionId" type="action"
            invisible="x_installment_invoice_count == 0">
      <field name="x_installment_invoice_count" widget="statinfo" string="განვ. ინვოისები"/>
    </button>
  </xpath>
  <xpath expr="//notebook/page[@name='order_lines']" position="after">
    <page string="განვადების გრაფიკი" name="installment_schedule">
      <field name="x_schedule_stale" invisible="1"/>
      <field name="x_schedule_snapshot" invisible="1"/>
      <field name="x_has_weekend" invisible="1"/>
      <div class="alert alert-warning" role="alert" invisible="not x_schedule_stale">
        ⚠️ გრაფიკი მოძველებულია — პარამეტრები ან თანხა შეიცვალა გენერაციის შემდეგ. დააჭირეთ „გრაფიკის გენერაციას" თავიდან.
      </div>
      <group>
        <group string="პარამეტრები">
          <field name="x_payment_type"/>
          <field name="x_first_tranche_pct" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_pct" invisible="x_payment_type != 'installment'"/>
          <field name="x_first_payment_date"/>
          <field name="x_schedule_start_date" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_interval" invisible="x_payment_type != 'installment'"/>
          <field name="x_project_end_date" invisible="x_payment_type != 'installment'"/>
        </group>
        <group string="თანხები">
          <field name="x_first_tranche_amount" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_amount" invisible="x_payment_type != 'installment'"/>
          <field name="x_final_balloon_amount" invisible="x_payment_type != 'installment'"/>
          <field name="x_bank_rate" invisible="x_payment_type == 'full_payment'"/>
          <field name="x_bank_term_months" invisible="x_payment_type == 'full_payment'"/>
          <field name="x_bank_pmt_reference" invisible="x_payment_type == 'full_payment'"/>
        </group>
      </group>
      <button name="$genActionId" type="action" string="გრაფიკის გენერაცია" class="btn-primary"/>
      <button name="$fixActionId" type="action" string="შაბ-კვ თარიღების გასწორება" class="btn-warning"
              invisible="not x_has_weekend"
              confirm="ყველა წითელი თარიღი გადაიწევს ორშაბათზე (შაბათი +2, კვირა +1 დღე) და მოინიშნება იასამნისფრად. გავაგრძელო?"/>
      <button name="$invActionId" type="action" string="ინვოისების გენერაცია" class="btn-secondary"
              invisible="not x_installment_line_ids or state != 'sale'"
              confirm="შეიქმნება draft ინვოისი გრაფიკის ყოველ შენატანზე. გავაგრძელო?"/>
      <field name="x_installment_line_ids" nolabel="1">
        <list editable="bottom" decoration-danger="x_is_weekend" decoration-primary="x_auto_fixed and not x_is_weekend" create="false">
          <field name="x_number" readonly="1"/>
          <field name="x_date"/>
          <field name="x_amount" sum="ჯამი"/>
          <field name="x_is_weekend" column_invisible="1"/>
          <field name="x_auto_fixed" column_invisible="1"/>
        </list>
      </field>
    </page>
  </xpath>
</data>
"@
$saleFormViewId = (Invoke-Odoo "ir.model.data" "check_object_reference" @("sale", "view_order_form"))[1]
Ensure-Record "ir.ui.view" @(, @("name", "=", "sale.order.form.figurebi.installment")) @{
    name = "sale.order.form.figurebi.installment"; model = "sale.order"; type = "form"
    inherit_id = $saleFormViewId; mode = "extension"; arch_base = $arch
} | Out-Null
Write-Host "view updated (v6)"

# 3. test: quotation blocked, confirmed passes
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$tmpId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"; x_first_tranche_pct = 10.0; x_schedule_pct = 10.0
    x_first_payment_date = "2026-09-01"; x_schedule_start_date = "2026-09-21"
    x_schedule_interval = 1; x_project_end_date = "2027-03-31"
}))
Invoke-Odoo "ir.actions.server" "run" @(, @($genActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
try {
    Invoke-Odoo "ir.actions.server" "run" @(, @($invActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
    Write-Host "TEST FAIL: quotation invoice-gen was NOT blocked!"
} catch { Write-Host "quotation blocked OK: $($_.Exception.Message)" }
Invoke-Odoo "sale.order" "action_confirm" @(, @($tmpId)) | Out-Null
Invoke-Odoo "ir.actions.server" "run" @(, @($invActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
$cnt = Invoke-Odoo "account.move" "search" @(, @(@("invoice_origin", "=", (Invoke-Odoo "sale.order" "read" @(@($tmpId), @("name"))).name), @("move_type", "=", "out_invoice")))
Write-Host "after confirm: created $(@($cnt).Count) invoices (expect > 0)"
# cleanup
Invoke-Odoo "account.move" "unlink" @(, @($cnt)) | Out-Null
Invoke-Odoo "sale.order" "action_cancel" @(, @($tmpId)) | Out-Null
Invoke-Odoo "sale.order" "unlink" @(, @($tmpId)) | Out-Null
Write-Host "cleanup done"
Write-Host "STATE GUARD DONE"
