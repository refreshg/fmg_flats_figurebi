﻿# Adds the reference-style header cards to the schedule tab: deal no, object
# code + m2, initial price per m2, initial total. Styled like the sample widget.
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

# 1. header info fields
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_object_ref")) @{
    model_id = $saleModelId; name = "x_object_ref"; state = "manual"
    field_description = "უძრავი ქონების № / მ²"; ttype = "char"; store = $false
    depends = "order_line.product_id,order_line.product_uom_qty"
    compute = "for r in self:`n    line = r.order_line.filtered(lambda l: not l.display_type)[:1]`n    if line and line.product_id:`n        r['x_object_ref'] = '%s / %s მ²' % (line.product_id.default_code or line.product_id.name, ('%g' % line.product_uom_qty))`n    else:`n        r['x_object_ref'] = ''"
} | Out-Null
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_price_per_m2")) @{
    model_id = $saleModelId; name = "x_price_per_m2"; state = "manual"
    field_description = "საწყისი კვ.მ ღირებულება"; ttype = "float"; store = $false
    depends = "order_line.price_unit"
    compute = "for r in self:`n    line = r.order_line.filtered(lambda l: not l.display_type)[:1]`n    r['x_price_per_m2'] = line.price_unit if line else 0.0"
} | Out-Null
Write-Host "header fields ok"

# 2. CSS: extend the asset with card styles (full rewrite of the attachment)
$css = @'
/* FIGUREBI: auto-fixed (purple) installment rows - bold dark purple on light purple bg */
div[name="x_installment_line_ids"] tr.text-primary td {
    background-color: #f0dcff !important;
    color: #6a1b9a !important;
    font-weight: 700;
}
div[name="x_installment_line_ids"] tr.text-danger td {
    font-weight: 700;
}
/* FIGUREBI: header info cards (reference-widget style) */
.figurebi_header {
    display: flex;
    gap: 14px;
    flex-wrap: wrap;
    margin-bottom: 16px;
}
.figurebi_card {
    flex: 1 1 180px;
    background: #f2f4ff;
    border: 1px solid #d9defc;
    border-radius: 10px;
    padding: 10px 14px;
}
.figurebi_card .figurebi_label {
    font-size: 11px;
    color: #6b7280;
    margin-bottom: 4px;
}
.figurebi_card .figurebi_value,
.figurebi_card .figurebi_value .o_field_widget,
.figurebi_card .figurebi_value span {
    font-weight: 700;
    font-size: 15px;
    color: #2743a6;
}
'@
$cssB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($css))
$attId = [int]@(Invoke-Odoo "ir.attachment" "search" @(, @(, @("name", "=", "figurebi_schedule.css"))))[0]
Invoke-Odoo "ir.attachment" "write" @(@($attId), @{datas = $cssB64; public = $true; mimetype = "text/css"}) | Out-Null
Write-Host "css updated (attachment id=$attId)"

# 3. view v12: header cards above everything
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
      <div class="figurebi_header">
        <div class="figurebi_card">
          <div class="figurebi_label">დილი</div>
          <div class="figurebi_value"><field name="name" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card">
          <div class="figurebi_label">უძრავი ქონების № / მ²</div>
          <div class="figurebi_value"><field name="x_object_ref" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card">
          <div class="figurebi_label">საწყისი კვ.მ ღირებულება</div>
          <div class="figurebi_value"><field name="x_price_per_m2" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card">
          <div class="figurebi_label">საწყისი ჯამური ღირებულება</div>
          <div class="figurebi_value"><field name="x_initial_total" readonly="1" nolabel="1"/></div>
        </div>
      </div>
      <div class="alert alert-warning" role="alert" invisible="not x_schedule_stale">
        ⚠️ გრაფიკი მოძველებულია — პარამეტრები ან თანხა შეიცვალა გენერაციის შემდეგ. დააჭირეთ „გრაფიკის გენერაციას" თავიდან.
      </div>
      <group>
        <group string="ფასდაკლება">
          <field name="x_discount_per_m2"/>
          <field name="x_discount_total"/>
          <field name="amount_total" string="საბოლოო ფასი" readonly="1"/>
        </group>
        <group string="პარამეტრები">
          <field name="x_payment_type"/>
          <field name="x_first_payment_date"/>
          <field name="x_schedule_start_date" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_interval" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_months" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულებამდე"/>
          <field name="x_final_payment_date" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულების თვის 15"/>
          <field name="x_project_end_date" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_end_date" readonly="1"
                 invisible="x_payment_type != 'installment' or not x_installment_line_ids"/>
        </group>
        <group string="განვადების სტრუქტურა" invisible="x_payment_type != 'installment'">
          <label for="x_first_tranche_pct" string="პირველი ტრანში"/>
          <div class="o_row">
            <field name="x_first_tranche_pct" class="oe_inline"/>
            <span>% =</span>
            <field name="x_first_tranche_amount" class="oe_inline"/>
          </div>
          <label for="x_schedule_pct" string="გრაფიკით გადაიხდის"/>
          <div class="o_row">
            <field name="x_schedule_pct" class="oe_inline" readonly="1"/>
            <span>% =</span>
            <field name="x_schedule_amount" class="oe_inline" readonly="1"/>
          </div>
          <label for="x_final_balloon_pct" string="ბოლო გადახდა"/>
          <div class="o_row">
            <field name="x_final_balloon_pct" class="oe_inline"/>
            <span>% =</span>
            <field name="x_final_balloon_amount" class="oe_inline"/>
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
Write-Host "view updated (v12)"

# 4. sanity: computed header fields on demo S01058
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01058"))))[0]
$r = Invoke-Odoo "sale.order" "read" @(@($soId), @("name", "x_object_ref", "x_price_per_m2", "x_initial_total"))
$r | ConvertTo-Json -Depth 3
Write-Host "HEADER CARDS DONE"
