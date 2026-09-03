﻿# Deploys the FIGUREBI installment calculator to Odoo staging via JSON-RPC,
# using manual models/fields, a server action, and an inherited view.
# No git / module upload required. Idempotent: re-running updates existing records.
$ErrorActionPreference = "Stop"
$base = "https://communapp-com-staging-37061251.dev.odoo.com"
$db = "communapp-com-staging-37061251"
$login = "admin"
$key = $env:FIGUREBI_STAGING_KEY  # staging admin password -> SECRETS.local.md

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") {
        throw ("Odoo error: " + ($r.error | ConvertTo-Json -Depth 10))
    }
    return $r.result
}

$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $login, $key, @{})
Write-Host "Authenticated uid=$script:uid"

function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}

function Get-XmlId($module, $name) {
    $res = Invoke-Odoo "ir.model.data" "check_object_reference" @($module, $name)
    return $res[1]
}

# --- helpers: idempotent create ---------------------------------------------
function Ensure-Record($model, $domain, $vals) {
    $found = Invoke-Odoo $model "search" @(, $domain)
    if ($found.Count -gt 0) {
        Invoke-Odoo $model "write" @(@($found[0]), $vals) | Out-Null
        return [int]$found[0]
    }
    return [int](Invoke-Odoo $model "create" @(, $vals))
}

# --- 1. manual model: installment line --------------------------------------
$lineModelId = Ensure-Record "ir.model" @(, @("model", "=", "x_figurebi_installment_line")) @{
    name = "FIGUREBI Installment Line"; model = "x_figurebi_installment_line"; state = "manual"
}
Write-Host "line model id=$lineModelId"

$saleModelId = [int](Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]
Write-Host "sale.order model id=$saleModelId"

function Ensure-Field($modelId, $name, $vals) {
    $vals["model_id"] = $modelId
    $vals["name"] = $name
    $vals["state"] = "manual"
    return Ensure-Record "ir.model.fields" @(@("model_id", "=", $modelId), @("name", "=", $name)) $vals
}

# line fields
Ensure-Field $lineModelId "x_order_id" @{
    field_description = "შეკვეთა"; ttype = "many2one"; relation = "sale.order"
    required = $true; on_delete = "cascade"; index = $true
} | Out-Null
Ensure-Field $lineModelId "x_number" @{ field_description = "N"; ttype = "integer" } | Out-Null
Ensure-Field $lineModelId "x_date" @{ field_description = "თარიღი"; ttype = "date"; required = $true } | Out-Null
Ensure-Field $lineModelId "x_amount" @{ field_description = "თანხა"; ttype = "float" } | Out-Null
Ensure-Field $lineModelId "x_is_weekend" @{
    field_description = "შაბათ-კვირა"; ttype = "boolean"; store = $false
    depends = "x_date"
    compute = "for r in self:`n    r['x_is_weekend'] = bool(r.x_date) and r.x_date.weekday() >= 5"
} | Out-Null
Write-Host "line fields ok"

# --- 2. fields on sale.order -------------------------------------------------
$payTypeFieldId = Ensure-Field $saleModelId "x_payment_type" @{
    field_description = "გადახდის ტიპი"; ttype = "selection"
}
# selection values (idempotent)
$selVals = @(@("installment", "შიდა განვადება"), @("bank_loan", "ბანკის სესხი"), @("full_payment", "ერთიანი გადახდა"))
$seq = 1
foreach ($sv in $selVals) {
    Ensure-Record "ir.model.fields.selection" @(@("field_id", "=", $payTypeFieldId), @("value", "=", $sv[0])) @{
        field_id = $payTypeFieldId; value = $sv[0]; name = $sv[1]; sequence = $seq
    } | Out-Null
    $seq++
}

Ensure-Field $saleModelId "x_first_tranche_pct" @{ field_description = "პირველი ტრანშის %"; ttype = "float" } | Out-Null
Ensure-Field $saleModelId "x_schedule_pct" @{ field_description = "გრაფიკით გადაიხდის %"; ttype = "float" } | Out-Null
Ensure-Field $saleModelId "x_first_payment_date" @{ field_description = "პირველი გადახდის თარიღი"; ttype = "date" } | Out-Null
Ensure-Field $saleModelId "x_schedule_start_date" @{ field_description = "გრაფიკის დაწყების თარიღი"; ttype = "date" } | Out-Null
Ensure-Field $saleModelId "x_schedule_interval" @{ field_description = "გრაფიკის ინტერვალი (თვე)"; ttype = "integer" } | Out-Null
Ensure-Field $saleModelId "x_project_end_date" @{ field_description = "პროექტის დასრულების თარიღი"; ttype = "date" } | Out-Null
Ensure-Field $saleModelId "x_bank_rate" @{ field_description = "საბანკო განაკვეთი %"; ttype = "float" } | Out-Null
Ensure-Field $saleModelId "x_bank_term_months" @{ field_description = "სესხის ვადა (თვე)"; ttype = "integer" } | Out-Null

Ensure-Field $saleModelId "x_first_tranche_amount" @{
    field_description = "პირველი ტრანში"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_pct"
    compute = "for r in self:`n    r['x_first_tranche_amount'] = round(r.amount_total * (r.x_first_tranche_pct or 0.0) / 100.0, 2)"
} | Out-Null
Ensure-Field $saleModelId "x_schedule_amount" @{
    field_description = "გრაფიკით გადაიხდის"; ttype = "float"; store = $false
    depends = "amount_total,x_schedule_pct"
    compute = "for r in self:`n    r['x_schedule_amount'] = round(r.amount_total * (r.x_schedule_pct or 0.0) / 100.0, 2)"
} | Out-Null
Ensure-Field $saleModelId "x_final_balloon_amount" @{
    field_description = "ბოლო გადახდა (ნაშთი)"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_pct,x_schedule_pct"
    compute = "for r in self:`n    f = round(r.amount_total * (r.x_first_tranche_pct or 0.0) / 100.0, 2)`n    s = round(r.amount_total * (r.x_schedule_pct or 0.0) / 100.0, 2)`n    r['x_final_balloon_amount'] = round(r.amount_total - f - s, 2)"
} | Out-Null
Ensure-Field $saleModelId "x_bank_pmt_reference" @{
    field_description = "საბანკო შენატანი (საცნობარო)"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_pct,x_schedule_pct,x_bank_rate,x_bank_term_months"
    compute = "for r in self:`n    p = r.amount_total * (1 - ((r.x_first_tranche_pct or 0.0) + (r.x_schedule_pct or 0.0)) / 100.0)`n    m = r.x_bank_term_months or 0`n    rate = (r.x_bank_rate or 0.0) / 100.0 / 12.0`n    if p <= 0 or m <= 0:`n        r['x_bank_pmt_reference'] = 0.0`n    elif rate:`n        r['x_bank_pmt_reference'] = round(p * rate / (1 - (1 + rate) ** -m), 2)`n    else:`n        r['x_bank_pmt_reference'] = round(p / m, 2)"
} | Out-Null
Ensure-Field $saleModelId "x_installment_line_ids" @{
    field_description = "განვადების გრაფიკი"; ttype = "one2many"
    relation = "x_figurebi_installment_line"; relation_field = "x_order_id"; copied = $false
} | Out-Null
Write-Host "sale.order fields ok"

# --- 3. access rights ---------------------------------------------------------
$salesGroupId = Get-XmlId "sales_team" "group_sale_salesman"
Ensure-Record "ir.model.access" @(, @("name", "=", "figurebi.installment.line.salesman")) @{
    name = "figurebi.installment.line.salesman"; model_id = $lineModelId; group_id = $salesGroupId
    perm_read = $true; perm_write = $true; perm_create = $true; perm_unlink = $true
} | Out-Null
Write-Host "access ok"

# --- 4. defaults --------------------------------------------------------------
Invoke-Odoo "ir.default" "set" @("sale.order", "x_payment_type", "installment") | Out-Null
Invoke-Odoo "ir.default" "set" @("sale.order", "x_first_tranche_pct", 10.0) | Out-Null
Invoke-Odoo "ir.default" "set" @("sale.order", "x_schedule_pct", 10.0) | Out-Null
Invoke-Odoo "ir.default" "set" @("sale.order", "x_schedule_interval", 1) | Out-Null
Invoke-Odoo "ir.default" "set" @("sale.order", "x_bank_rate", 14.0) | Out-Null
Invoke-Odoo "ir.default" "set" @("sale.order", "x_bank_term_months", 120) | Out-Null
Write-Host "defaults ok"

# --- 5. server action: generate schedule --------------------------------------
$actionCode = @'
# Generates the installment schedule for the selected sale order(s).
# Mirrors the company's Excel calculator (sheet "100"):
# first tranche + N-monthly installments (capped at the 15th of the
# completion month) + final remainder (balloon). Weekend dates are kept
# as-is; the x_is_weekend flag marks them red for manual correction.
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
        first_pct = order.x_first_tranche_pct or 0.0
        sched_pct = order.x_schedule_pct or 0.0
        if first_pct < 0 or sched_pct < 0:
            raise UserError("პროცენტები უარყოფითი ვერ იქნება.")
        if first_pct + sched_pct > 100.001:
            raise UserError("პირველი ტრანშისა და გრაფიკის პროცენტების ჯამი 100%-ს ვერ გადააჭარბებს.")
        if not order.x_schedule_start_date or not order.x_project_end_date:
            raise UserError("შეავსეთ გრაფიკის დაწყებისა და პროექტის დასრულების თარიღები.")
        if order.x_schedule_start_date > order.x_project_end_date:
            raise UserError("გრაფიკის დაწყების თარიღი პროექტის დასრულებაზე გვიან ვერ იქნება.")
        interval = int(order.x_schedule_interval or 1)
        if interval < 1:
            raise UserError("გრაფიკის ინტერვალი მინიმუმ 1 თვეა.")
        first_amt = round(total * first_pct / 100.0, 2)
        sched_amt = round(total * sched_pct / 100.0, 2)
        vals_list.append({'x_order_id': order.id, 'x_number': 1, 'x_date': order.x_first_payment_date, 'x_amount': first_amt})
        cap = datetime.date(order.x_project_end_date.year, order.x_project_end_date.month, 15)
        dates = []
        k = 0
        while True:
            d = order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=k * interval)
            if d > order.x_project_end_date:
                break
            if d >= cap:
                dates.append(cap)
                break
            dates.append(d)
            k += 1
        n = len(dates)
        has_balloon = (first_pct + sched_pct) < 99.999
        divisor = n - 1 if has_balloon else n
        if divisor < 1:
            raise UserError("თარიღების მიხედვით გრაფიკში საკმარისი შენატანი ვერ თავსდება — შეამოწმეთ დაწყების/დასრულების თარიღები და ინტერვალი.")
        per = round(sched_amt / divisor, 2)
        paid = first_amt
        i = 0
        for d in dates:
            # the last row is always the remainder: absorbs balloon + rounding
            amt = per if i < n - 1 else round(total - paid, 2)
            paid += amt
            vals_list.append({'x_order_id': order.id, 'x_number': i + 2, 'x_date': d, 'x_amount': amt})
            i += 1
    env['x_figurebi_installment_line'].create(vals_list)
'@

$actionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) @{
    name = "FIGUREBI: გრაფიკის გენერაცია"; model_id = $saleModelId; state = "code"; code = $actionCode
}
Write-Host "server action id=$actionId"

# --- 6. view: notebook page on sale order form --------------------------------
$saleFormViewId = Get-XmlId "sale" "view_order_form"
$arch = @"
<data>
  <xpath expr="//notebook/page[@name='order_lines']" position="after">
    <page string="განვადების გრაფიკი" name="installment_schedule">
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
      <button name="$actionId" type="action" string="გრაფიკის გენერაცია" class="btn-primary"/>
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

Ensure-Record "ir.ui.view" @(, @("name", "=", "sale.order.form.figurebi.installment")) @{
    name = "sale.order.form.figurebi.installment"; model = "sale.order"; type = "form"
    inherit_id = $saleFormViewId; mode = "extension"; arch_base = $arch
} | Out-Null
Write-Host "view ok"
Write-Host "DEPLOY DONE"
