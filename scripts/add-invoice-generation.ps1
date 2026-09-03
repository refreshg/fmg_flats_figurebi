﻿# Adds "generate invoices from schedule": a service product for installment fees,
# a server action creating one draft customer invoice per schedule line (due date =
# line date), and a button on the schedule tab. Then runs it on the demo order.
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

# 1. service product used on installment invoices
$feeProdId = Ensure-Record "product.product" @(, @("default_code", "=", "INSTALLMENT-FEE")) @{
    name = "განვადების შენატანი"; default_code = "INSTALLMENT-FEE"; type = "service"
    list_price = 0; taxes_id = @(, @(6, 0, @()))
}
Write-Host "fee product id=$feeProdId"

$saleModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]

# 2. server action: one draft invoice per schedule line
$invActionCode = @'
# Creates one draft customer invoice per installment line: due date = the line's
# date, amount = the line's amount (tax-free, matches the schedule exactly).
for order in records:
    lines = order.x_installment_line_ids.sorted(key=lambda l: l.x_number)
    if not lines:
        raise UserError("ჯერ დააგენერირეთ განვადების გრაფიკი.")
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
$invActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ინვოისების გენერაცია")) @{
    name = "FIGUREBI: ინვოისების გენერაცია"; model_id = $saleModelId; state = "code"; code = $invActionCode
}
Write-Host "invoice action id=$invActionId"

# 3. view: add the invoice button next to the generate button (arch v3 — canonical)
$genActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
$arch = @"
<data>
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
Write-Host "view updated (v3)"

# 4. run it on the demo order S01054
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01054"))))[0]
Invoke-Odoo "ir.actions.server" "run" @(, @($invActionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$invs = Invoke-Odoo "account.move" "search_read" @(@(@("invoice_origin", "=", "S01054"), @("move_type", "=", "out_invoice")), @("name", "invoice_date_due", "amount_total", "state")) @{order = "invoice_date_due"}
Write-Host "created invoices:"
$sum = 0
foreach ($i in $invs) { $sum += $i.amount_total; Write-Host ("{0}`tdue {1}`t{2}`t{3}" -f $i.name, $i.invoice_date_due, $i.amount_total, $i.state) }
Write-Host "invoice count = $(@($invs).Count), sum = $sum"
Write-Host "INVOICE GENERATION DONE"
