﻿# Pairs each percentage with its amount on one row (tranche / schedule / final
# balloon) and adds the computed final-payment percent. View v10.
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

# 1. computed final-payment percent
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_final_balloon_pct")) @{
    model_id = $saleModelId; name = "x_final_balloon_pct"; state = "manual"
    field_description = "ბოლო გადახდის %"; ttype = "float"; store = $false
    depends = "x_first_tranche_pct,x_schedule_pct"
    compute = "for r in self:`n    r['x_final_balloon_pct'] = round(max(0.0, 100.0 - (r.x_first_tranche_pct or 0.0) - (r.x_schedule_pct or 0.0)), 2)"
} | Out-Null
Write-Host "balloon pct field ok"

# 2. view v10: paired % + amount rows
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
          <field name="x_first_payment_date"/>
          <field name="x_schedule_start_date" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_end_date" readonly="1"
                 invisible="x_payment_type != 'installment' or not x_installment_line_ids"/>
          <field name="x_schedule_interval" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_months" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულებამდე"/>
          <field name="x_project_end_date" invisible="x_payment_type != 'installment'"/>
        </group>
        <group string="განვადების სტრუქტურა" invisible="x_payment_type != 'installment'">
          <label for="x_first_tranche_pct" string="პირველი ტრანში"/>
          <div class="o_row">
            <field name="x_first_tranche_pct" class="oe_inline"/>
            <span>% =</span>
            <field name="x_first_tranche_amount" class="oe_inline" readonly="1"/>
          </div>
          <label for="x_schedule_pct" string="გრაფიკით გადაიხდის"/>
          <div class="o_row">
            <field name="x_schedule_pct" class="oe_inline"/>
            <span>% =</span>
            <field name="x_schedule_amount" class="oe_inline" readonly="1"/>
          </div>
          <label for="x_final_balloon_pct" string="ბოლო გადახდა (ნაშთი)"/>
          <div class="o_row">
            <field name="x_final_balloon_pct" class="oe_inline" readonly="1"/>
            <span>% =</span>
            <field name="x_final_balloon_amount" class="oe_inline" readonly="1"/>
          </div>
        </group>
        <group string="საბანკო (საცნობარო)" invisible="x_payment_type == 'full_payment'">
          <field name="x_bank_rate"/>
          <field name="x_bank_term_months"/>
          <field name="x_bank_pmt_reference" readonly="1"/>
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
          <field name="x_balance" readonly="1"/>
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
Write-Host "view updated (v10)"

# 3. sanity check on S01058
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01058"))))[0]
$r = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_first_tranche_pct", "x_first_tranche_amount", "x_schedule_pct", "x_schedule_amount", "x_final_balloon_pct", "x_final_balloon_amount"))
$r | ConvertTo-Json -Depth 3
Write-Host "PAIRED PERCENTS DONE"
