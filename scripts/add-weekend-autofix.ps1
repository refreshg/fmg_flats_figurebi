﻿# Adds the "fix weekend dates" button: shifts every red (weekend) schedule date
# to Monday (Sat +2, Sun +1) and marks those rows purple (x_auto_fixed) so the
# manager can still adjust specific ones manually; a manual date edit clears the
# purple mark. Idempotent.
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
$lineModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "x_figurebi_installment_line"))))[0]

# 1. fields: x_auto_fixed on lines; x_has_weekend helper on the order
Ensure-Record "ir.model.fields" @(@("model_id", "=", $lineModelId), @("name", "=", "x_auto_fixed")) @{
    model_id = $lineModelId; name = "x_auto_fixed"; state = "manual"
    field_description = "ავტო-გასწორებული"; ttype = "boolean"
    help = "Date was shifted off a weekend automatically; shown purple until edited manually."
} | Out-Null
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_has_weekend")) @{
    model_id = $saleModelId; name = "x_has_weekend"; state = "manual"
    field_description = "აქვს შაბ-კვ თარიღები"; ttype = "boolean"; store = $false
    depends = "x_installment_line_ids.x_date"
    compute = "for r in self:`n    r['x_has_weekend'] = bool(r.x_installment_line_ids.filtered(lambda l: l.x_date and l.x_date.weekday() >= 5))"
} | Out-Null
Write-Host "fields ok"

# 2. fix action: shift weekend dates to Monday, mark purple
$fixCode = @'
# Shifts every weekend schedule date to the following Monday (Sat +2, Sun +1)
# and marks the row as auto-fixed (purple). Runs with a context flag so the
# purple-clearing automation ignores these writes.
for order in records:
    bad = order.x_installment_line_ids.filtered(lambda l: l.x_is_weekend)
    if not bad:
        raise UserError("წითელი (შაბათ-კვირის) თარიღები არ არის — გასასწორებელი არაფერია.")
    for line in bad:
        d = line.x_date
        shift = 2 if d.weekday() == 5 else 1
        line.with_context(figurebi_autofix=True).write({
            'x_date': d + datetime.timedelta(days=shift),
            'x_auto_fixed': True,
        })
'@
$fixActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: შაბ-კვ თარიღების გასწორება")) @{
    name = "FIGUREBI: შაბ-კვ თარიღების გასწორება"; model_id = $saleModelId; state = "code"; code = $fixCode
}
Write-Host "fix action id=$fixActionId"

# 3. automation: manual date edit clears the purple mark
$dateFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $lineModelId), @("name", "=", "x_date"))))[0]
$clearAutoId = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ხელით შესწორებაზე იასამნისფრის მოხსნა")) @{
    name = "FIGUREBI: ხელით შესწორებაზე იასამნისფრის მოხსნა"
    model_id = $lineModelId
    trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($dateFieldId)))
    active = $true
}
$clearCode = @'
# A manual change of the date means the manager made their own choice:
# drop the auto-fixed (purple) mark. Writes from the auto-fix action carry
# figurebi_autofix in context and are ignored.
if not env.context.get('figurebi_autofix'):
    for line in records:
        if line.x_auto_fixed:
            line.with_context(figurebi_autofix=True).write({'x_auto_fixed': False})
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: იასამნისფრის მოხსნის მოქმედება")) @{
    name = "FIGUREBI: იასამნისფრის მოხსნის მოქმედება"; model_id = $lineModelId; state = "code"; code = $clearCode
    usage = "base_automation"; base_automation_id = $clearAutoId
} | Out-Null
Write-Host "clear automation ok (id=$clearAutoId)"

# 4. view v5: fix button + purple decoration
$genActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
$invActionId = [int]@(Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: ინვოისების გენერაცია"))))[0]
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
              invisible="not x_installment_line_ids"
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
Write-Host "view updated (v5)"

# 5. e2e test on a temp order (schedule start Saturday)
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
Invoke-Odoo "ir.actions.server" "run" @(, @($fixActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
$lines = @(Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $tmpId)), @("id", "x_number", "x_date", "x_is_weekend", "x_auto_fixed")) @{order = "x_number"})
Write-Host "after auto-fix:"
foreach ($l in $lines) {
    $d = [datetime]$l.x_date
    $mark = ""
    if ($l.x_is_weekend) { $mark = " <-- STILL WEEKEND!" }
    if ($l.x_auto_fixed) { $mark += " [purple]" }
    Write-Host ("{0}`t{1} ({2}){3}" -f $l.x_number, $l.x_date, $d.DayOfWeek, $mark)
}
$stillWeekend = @($lines | Where-Object { $_.x_is_weekend }).Count
Write-Host "still-weekend count = $stillWeekend (expect 0)"
# manual edit clears purple
$purple = @($lines | Where-Object { $_.x_auto_fixed })
if ($purple.Count -gt 0) {
    $target = [int]$purple[0].id
    $newDate = ([datetime]$purple[0].x_date).AddDays(4).ToString("yyyy-MM-dd")
    Invoke-Odoo "x_figurebi_installment_line" "write" @(@($target), @{x_date = $newDate}) | Out-Null
    $after = Invoke-Odoo "x_figurebi_installment_line" "read" @(@($target), @("x_date", "x_auto_fixed"))
    Write-Host ("manual edit test: date={0}, auto_fixed={1} (expect False)" -f $after.x_date, $after.x_auto_fixed)
}
Invoke-Odoo "sale.order" "unlink" @(, @($tmpId)) | Out-Null
Write-Host "temp SO removed"
Write-Host "WEEKEND AUTOFIX DONE"
