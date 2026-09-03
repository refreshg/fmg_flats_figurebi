﻿# Reworks the calculator to match the reference widget:
#  - first tranche and final payment enterable as BOTH $ and % (two-way sync)
#  - schedule part becomes the computed remainder (100% - first - final)
#  - final payment date manually enterable (empty = 15th of completion month)
#  - discount enterable in $ (per m2 or total) writing the line's Disc.%
# Updates generation action + stale signature (both places). View v11. Idempotent.
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
function Ensure-SaleField($name, $vals) {
    $vals["model_id"] = $saleModelId; $vals["name"] = $name; $vals["state"] = "manual"
    return Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", $name)) $vals
}

# --- 1. field conversions & new fields ---------------------------------------
# first tranche amount: editable stored (was computed)
Ensure-SaleField "x_first_tranche_amount" @{
    field_description = "პირველი ტრანში ($)"; ttype = "float"; store = $true; compute = $false; depends = $false; readonly = $false
} | Out-Null
# final balloon pct/amount: editable stored (were computed)
Ensure-SaleField "x_final_balloon_pct" @{
    field_description = "ბოლო გადახდის %"; ttype = "float"; store = $true; compute = $false; depends = $false; readonly = $false
} | Out-Null
Ensure-SaleField "x_final_balloon_amount" @{
    field_description = "ბოლო გადახდა ($)"; ttype = "float"; store = $true; compute = $false; depends = $false; readonly = $false
} | Out-Null
# schedule part: computed remainder now
Ensure-SaleField "x_schedule_pct" @{
    field_description = "გრაფიკით გადაიხდის %"; ttype = "float"; store = $false
    depends = "x_first_tranche_pct,x_final_balloon_pct"
    compute = "for r in self:`n    r['x_schedule_pct'] = round(max(0.0, 100.0 - (r.x_first_tranche_pct or 0.0) - (r.x_final_balloon_pct or 0.0)), 4)"
} | Out-Null
Ensure-SaleField "x_schedule_amount" @{
    field_description = "გრაფიკით გადაიხდის ($)"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_amount,x_final_balloon_amount"
    compute = "for r in self:`n    r['x_schedule_amount'] = round((r.amount_total or 0.0) - (r.x_first_tranche_amount or 0.0) - (r.x_final_balloon_amount or 0.0), 2)"
} | Out-Null
# final payment date (manual; empty = old 15th rule)
Ensure-SaleField "x_final_payment_date" @{
    field_description = "ბოლო შენატანის თარიღი"; ttype = "date"
    help = "Empty = automatic (the 15th of the completion month)."
} | Out-Null
# discount in dollars + initial total display
Ensure-SaleField "x_discount_per_m2" @{
    field_description = "ფასდაკლება კვ.მ-ზე ($)"; ttype = "float"
} | Out-Null
Ensure-SaleField "x_discount_total" @{
    field_description = "ფასდაკლება სრული ($)"; ttype = "float"
} | Out-Null
Ensure-SaleField "x_initial_total" @{
    field_description = "საწყისი ჯამური ფასი"; ttype = "float"; store = $false
    depends = "order_line.price_unit,order_line.product_uom_qty"
    compute = "for r in self:`n    r['x_initial_total'] = round(sum((l.price_unit or 0.0) * (l.product_uom_qty or 0.0) for l in r.order_line.filtered(lambda l: not l.display_type)), 2)"
} | Out-Null
Write-Host "fields ok"

# defaults: drop old schedule-pct default, add balloon default 80
Invoke-Odoo "ir.default" "set" @("sale.order", "x_final_balloon_pct", 80.0) | Out-Null
$schedFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", "x_schedule_pct"))))[0]
$oldDef = @(Invoke-Odoo "ir.default" "search" @(, @(, @("field_id", "=", $schedFieldId))))
if ($oldDef.Count -gt 0) { Invoke-Odoo "ir.default" "unlink" @(, @($oldDef)) | Out-Null; Write-Host "old schedule default removed" }
Write-Host "defaults ok"

# --- 2. sync automations ------------------------------------------------------
function Get-FieldIds($names) {
    $ids = @()
    foreach ($n in $names) { $ids += [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", $n))))[0] }
    return $ids
}
# 2a. % -> $ (also refresh on total change)
$autoA = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: სინქრონი % -> $")) @{
    name = "FIGUREBI: სინქრონი % -> $"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, (Get-FieldIds @("x_first_tranche_pct", "x_final_balloon_pct", "amount_total")))); active = $true
}
$codeA = @'
# Percent changed (or the order total changed): refresh the $ amounts.
if not env.context.get('figurebi_sync'):
    for order in records:
        total = order.amount_total or 0.0
        order.with_context(figurebi_sync=True).write({
            'x_first_tranche_amount': round(total * (order.x_first_tranche_pct or 0.0) / 100.0, 2),
            'x_final_balloon_amount': round(total * (order.x_final_balloon_pct or 0.0) / 100.0, 2),
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: სინქრონი %->$ მოქმედება")) @{
    name = "FIGUREBI: სინქრონი %->$ მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeA
    usage = "base_automation"; base_automation_id = $autoA
} | Out-Null
# 2b. $ -> %
$autoB = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: სინქრონი $ -> %")) @{
    name = "FIGUREBI: სინქრონი $ -> %"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, (Get-FieldIds @("x_first_tranche_amount", "x_final_balloon_amount")))); active = $true
}
$codeB = @'
# Dollar amount changed manually: refresh the percentages.
if not env.context.get('figurebi_sync'):
    for order in records:
        total = order.amount_total or 0.0
        if total:
            order.with_context(figurebi_sync=True).write({
                'x_first_tranche_pct': round((order.x_first_tranche_amount or 0.0) / total * 100.0, 4),
                'x_final_balloon_pct': round((order.x_final_balloon_amount or 0.0) / total * 100.0, 4),
            })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: სინქრონი $->% მოქმედება")) @{
    name = "FIGUREBI: სინქრონი $->% მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeB
    usage = "base_automation"; base_automation_id = $autoB
} | Out-Null
# 2c. discount $ -> line Disc.%
$autoC = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონი")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, (Get-FieldIds @("x_discount_per_m2", "x_discount_total")))); active = $true
}
$codeC = @'
# Discount entered in dollars (per m2 or total): translate to the line's Disc.%
# on the first product line and mirror the other dollar field.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        gross = line.price_unit * line.product_uom_qty
        per_m2 = order.x_discount_per_m2 or 0.0
        total_d = order.x_discount_total or 0.0
        # per-m2 wins when both are set and disagree with each other
        if per_m2 and abs(per_m2 * line.product_uom_qty - total_d) > 0.01:
            total_d = round(per_m2 * line.product_uom_qty, 2)
        elif total_d:
            per_m2 = round(total_d / line.product_uom_qty, 2)
        pct = round(total_d / gross * 100.0, 4) if gross else 0.0
        if pct < 0 or pct > 100:
            raise UserError("ფასდაკლება 0-სა და მთლიან ფასს შორის უნდა იყოს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_total': total_d,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeC
    usage = "base_automation"; base_automation_id = $autoC
} | Out-Null
Write-Host "sync automations ok"

# --- 3. generation action (canonical v4) -------------------------------------
$genCode = @'
# Generates the installment schedule. Structure: first tranche ($/% synced) +
# equal installments of the remainder + final payment ($/% synced) on its own
# date (x_final_payment_date; empty = the 15th of the completion month).
# Weekend dates stay as-is (red) for manual/бutton correction.
for order in records:
    total = order.amount_total
    if total <= 0:
        raise UserError("ჯამური ფასი უნდა იყოს 0-ზე მეტი — ჯერ დაამატეთ ობიექტი შეკვეთის ხაზებში.")
    if not order.x_first_payment_date:
        raise UserError("შეავსეთ პირველი გადახდის თარიღი.")
    ptype = order.x_payment_type or 'installment'
    order.x_installment_line_ids.unlink()
    vals_list = []
    if ptype in ('bank_loan', 'full_payment'):
        vals_list.append({'x_order_id': order.id, 'x_number': 1, 'x_date': order.x_first_payment_date, 'x_amount': total})
    else:
        first_amt = round(order.x_first_tranche_amount or 0.0, 2)
        balloon_amt = round(order.x_final_balloon_amount or 0.0, 2)
        if first_amt < 0 or balloon_amt < 0:
            raise UserError("თანხები უარყოფითი ვერ იქნება.")
        sched_amt = round(total - first_amt - balloon_amt, 2)
        if sched_amt < -0.01:
            raise UserError("პირველი ტრანში + ბოლო გადახდა ჯამურ ფასს აჭარბებს.")
        if not order.x_schedule_start_date or not order.x_project_end_date:
            raise UserError("შეავსეთ გრაფიკის დაწყებისა და პროექტის დასრულების თარიღები.")
        if order.x_schedule_start_date > order.x_project_end_date:
            raise UserError("გრაფიკის დაწყების თარიღი პროექტის დასრულებაზე გვიან ვერ იქნება.")
        interval = int(order.x_schedule_interval or 1)
        if interval < 1:
            raise UserError("გრაფიკის ინტერვალი მინიმუმ 1 თვეა.")
        cap = datetime.date(order.x_project_end_date.year, order.x_project_end_date.month, 15)
        bdate = order.x_final_payment_date or cap
        vals_list.append({'x_order_id': order.id, 'x_number': 1, 'x_date': order.x_first_payment_date, 'x_amount': first_amt})
        months = int(order.x_schedule_months or 0)
        dates = []
        if months > 0:
            count = max(1, months // interval)
            for k in range(count):
                dates.append(order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=k * interval))
            if dates[-1] > order.x_project_end_date:
                raise UserError("გადანაწილების ვადა (%s თვე) სცდება პროექტის დასრულებას." % months)
        else:
            k = 0
            while True:
                d = order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=k * interval)
                if d > order.x_project_end_date or d >= cap:
                    break
                dates.append(d)
                k += 1
        if balloon_amt > 0.005 and dates and bdate <= dates[-1]:
            raise UserError("ბოლო შენატანის თარიღი (%s) გრაფიკის ბოლო შენატანზე (%s) გვიან უნდა იყოს." % (bdate, dates[-1]))
        n = len(dates)
        if sched_amt > 0.005:
            if n < 1:
                raise UserError("თარიღების მიხედვით გრაფიკში შენატანი ვერ თავსდება — შეამოწმეთ თარიღები/ინტერვალი.")
            per = round(sched_amt / n, 2)
            acc = 0.0
            i = 0
            for d in dates:
                # last schedule row absorbs rounding so the schedule part is exact
                amt = per if i < n - 1 else round(sched_amt - acc, 2)
                acc = round(acc + amt, 2)
                vals_list.append({'x_order_id': order.id, 'x_number': i + 2, 'x_date': d, 'x_amount': amt})
                i += 1
        if balloon_amt > 0.005:
            vals_list.append({'x_order_id': order.id, 'x_number': len(vals_list) + 1, 'x_date': bdate, 'x_amount': balloon_amt})
    env['x_figurebi_installment_line'].create(vals_list)
    # snapshot MUST match the signature in the x_schedule_stale compute
    sig = '|'.join([
        str(order.x_payment_type or ''),
        str(round(order.x_first_tranche_amount or 0.0, 2)),
        str(round(order.x_final_balloon_amount or 0.0, 2)),
        str(order.x_first_payment_date or ''),
        str(order.x_schedule_start_date or ''),
        str(order.x_schedule_interval or 1),
        str(order.x_schedule_months or 0),
        str(order.x_final_payment_date or ''),
        str(order.x_project_end_date or ''),
        str(round(order.amount_total or 0.0, 2)),
    ])
    order['x_schedule_snapshot'] = sig
'@
$genActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) @{
    name = "FIGUREBI: გრაფიკის გენერაცია"; model_id = $saleModelId; state = "code"; code = $genCode
}
Write-Host "generation action updated (v4)"

# --- 4. stale compute: same signature ----------------------------------------
$staleCompute = @'
for r in self:
    sig = '|'.join([
        str(r.x_payment_type or ''),
        str(round(r.x_first_tranche_amount or 0.0, 2)),
        str(round(r.x_final_balloon_amount or 0.0, 2)),
        str(r.x_first_payment_date or ''),
        str(r.x_schedule_start_date or ''),
        str(r.x_schedule_interval or 1),
        str(r.x_schedule_months or 0),
        str(r.x_final_payment_date or ''),
        str(r.x_project_end_date or ''),
        str(round(r.amount_total or 0.0, 2)),
    ])
    lines = r.x_installment_line_ids
    mismatch = bool(lines) and abs(sum(lines.mapped('x_amount')) - (r.amount_total or 0.0)) > 0.01
    r['x_schedule_stale'] = bool(lines) and ((r.x_schedule_snapshot or '') != sig or mismatch)
'@
Ensure-SaleField "x_schedule_stale" @{
    field_description = "გრაფიკი მოძველებულია"; ttype = "boolean"; store = $false
    depends = "x_payment_type,x_first_tranche_amount,x_final_balloon_amount,x_first_payment_date,x_schedule_start_date,x_schedule_interval,x_schedule_months,x_final_payment_date,x_project_end_date,amount_total,x_schedule_snapshot,x_installment_line_ids.x_amount"
    compute = $staleCompute
} | Out-Null
Write-Host "stale compute updated"

# --- 5. view v11 --------------------------------------------------------------
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
        <group string="ფასი და ფასდაკლება">
          <field name="x_initial_total" readonly="1"/>
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
Write-Host "view updated (v11)"
Write-Host "REWORK DONE (tests next)"
