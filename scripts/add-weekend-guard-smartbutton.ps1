﻿# 1) Blocks SO confirmation and invoice generation while the schedule contains
#    weekend (red) dates. 2) Adds a stat smart-button on the SO showing how many
#    installment invoices were issued, opening the filtered list. Idempotent.
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

# --- 1a. weekend check inside the invoice-generation action (full new code) ---
$invActionCode = @'
# Creates one draft customer invoice per installment line: due date = the line's
# date, amount = the line's amount (tax-free, matches the schedule exactly).
# Refuses to run while the schedule still contains weekend (red) dates.
for order in records:
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
Write-Host "invoice action updated with weekend check"

# --- 1b. block SO confirmation while weekend dates remain -------------------
$stateFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", "state"))))[0]
$guardAutoId = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: შაბ-კვ თარიღების დაცვა Confirm-ზე")) @{
    name = "FIGUREBI: შაბ-კვ თარიღების დაცვა Confirm-ზე"
    model_id = $saleModelId
    trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($stateFieldId)))
    active = $true
}
$guardCode = @'
# Blocks moving a sale order forward (sending the quotation OR confirming it)
# while its installment schedule still has weekend (red) dates awaiting
# manual correction.
for order in records:
    if order.state in ('sent', 'sale'):
        bad = order.x_installment_line_ids.filtered(lambda l: l.x_is_weekend)
        if bad:
            raise UserError("შემდეგ ეტაპზე გადასვლა შეუძლებელია: განვადების გრაფიკში შაბათ-კვირის (წითელი) თარიღებია: %s. ჯერ ხელით შეასწორეთ (ორშაბათზე ან პარასკევზე) და მერე გააგზავნეთ/დაადასტურეთ." % ', '.join([str(d) for d in bad.mapped('x_date')]))
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: შაბ-კვ დაცვის მოქმედება")) @{
    name = "FIGUREBI: შაბ-კვ დაცვის მოქმედება"; model_id = $saleModelId; state = "code"; code = $guardCode
    usage = "base_automation"; base_automation_id = $guardAutoId
} | Out-Null
Write-Host "confirm guard automation ok (id=$guardAutoId)"

# --- 2. invoice-count smart button ------------------------------------------
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_installment_invoice_count")) @{
    model_id = $saleModelId; name = "x_installment_invoice_count"; state = "manual"
    field_description = "განვადების ინვოისები"; ttype = "integer"; store = $false
    depends = "name"
    compute = "for r in self:`n    r['x_installment_invoice_count'] = self.env['account.move'].search_count([('invoice_origin', '=', r.name), ('move_type', '=', 'out_invoice'), ('state', '!=', 'cancel')])"
} | Out-Null

$statCode = @'
# Opens the list of installment invoices issued for this sale order.
if record:
    action = {
        'type': 'ir.actions.act_window',
        'name': 'განვადების ინვოისები',
        'res_model': 'account.move',
        'view_mode': 'list,form',
        'domain': [('invoice_origin', '=', record.name), ('move_type', '=', 'out_invoice')],
    }
'@
$statActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: განვადების ინვოისების ნახვა")) @{
    name = "FIGUREBI: განვადების ინვოისების ნახვა"; model_id = $saleModelId; state = "code"; code = $statCode
}
Write-Host "stat action id=$statActionId"

# --- 3. view arch v4: page + smart button in button_box ---------------------
$genActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
$invActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: ინვოისების გენერაცია"))))[0]
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
      <button name="$invActionId" type="action" string="ინვოისების გენერაცია" class="btn-secondary"
              invisible="not x_installment_line_ids"
              confirm="შეიქმნება draft ინვოისი გრაფიკის ყოველ შენატანზე. გავაგრძელო?"/>
      <field name="x_installment_line_ids" nolabel="1">
        <list editable="bottom" decoration-danger="x_is_weekend" create="false">
          <field name="x_number" readonly="1"/>
          <field name="x_date"/>
          <field name="x_amount" sum="ჯამი"/>
          <field name="x_is_weekend" column_invisible="1"/>
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
Write-Host "view updated (v4, smart button added)"

# --- 4. tests ----------------------------------------------------------------
# count on S01058 should be 14
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01058"))))[0]
$cnt = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_installment_invoice_count"))
Write-Host ("S01058 invoice count = " + ($cnt.x_installment_invoice_count))

# weekend guard: temp SO whose schedule starts on Saturday 2026-09-19
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$tmpId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"; x_first_tranche_pct = 10.0; x_schedule_pct = 10.0
    x_first_payment_date = "2026-09-01"; x_schedule_start_date = "2026-09-19"
    x_schedule_interval = 1; x_project_end_date = "2027-06-30"
}))
Invoke-Odoo "ir.actions.server" "run" @(, @($genActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
try {
    Invoke-Odoo "ir.actions.server" "run" @(, @($invActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
    Write-Host "TEST FAIL: invoice generation was NOT blocked!"
} catch { Write-Host "invoice-gen blocked OK: $($_.Exception.Message)" }
try {
    Invoke-Odoo "sale.order" "action_confirm" @(, @($tmpId)) | Out-Null
    Write-Host "TEST FAIL: confirmation was NOT blocked!"
} catch { Write-Host "confirm blocked OK: $($_.Exception.Message)" }
Invoke-Odoo "sale.order" "unlink" @(, @($tmpId)) | Out-Null
Write-Host "temp SO removed"
Write-Host "WEEKEND GUARD + SMART BUTTON DONE"
