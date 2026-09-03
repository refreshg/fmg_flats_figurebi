﻿# Adds a "schedule is stale" warning: generation stores a parameter snapshot;
# a computed flag compares current params/totals against it and the view shows
# a yellow alert when they diverge. Idempotent.
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

# 1. snapshot field (hidden) + stale flag (computed)
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_schedule_snapshot")) @{
    model_id = $saleModelId; name = "x_schedule_snapshot"; state = "manual"
    field_description = "გრაფიკის snapshot"; ttype = "char"
    help = "Parameter signature captured when the schedule was generated."
} | Out-Null

# NOTE: the signature built here MUST stay identical to the one in the server action.
$staleCompute = @'
for r in self:
    sig = '|'.join([
        str(r.x_payment_type or ''),
        str(round(r.x_first_tranche_pct or 0.0, 4)),
        str(round(r.x_schedule_pct or 0.0, 4)),
        str(r.x_first_payment_date or ''),
        str(r.x_schedule_start_date or ''),
        str(r.x_schedule_interval or 1),
        str(r.x_project_end_date or ''),
        str(round(r.amount_total or 0.0, 2)),
    ])
    lines = r.x_installment_line_ids
    mismatch = bool(lines) and abs(sum(lines.mapped('x_amount')) - (r.amount_total or 0.0)) > 0.01
    r['x_schedule_stale'] = bool(lines) and ((r.x_schedule_snapshot or '') != sig or mismatch)
'@
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_schedule_stale")) @{
    model_id = $saleModelId; name = "x_schedule_stale"; state = "manual"
    field_description = "გრაფიკი მოძველებულია"; ttype = "boolean"; store = $false
    depends = "x_payment_type,x_first_tranche_pct,x_schedule_pct,x_first_payment_date,x_schedule_start_date,x_schedule_interval,x_project_end_date,amount_total,x_schedule_snapshot,x_installment_line_ids.x_amount"
    compute = $staleCompute
} | Out-Null
Write-Host "fields ok"

# 2. server action: regenerate + store the snapshot
$actionCode = @'
# Generates the installment schedule for the selected sale order(s).
# Mirrors the company's Excel calculator (sheet "100"):
# first tranche + N-monthly installments (capped at the 15th of the
# completion month) + final remainder (balloon). Weekend dates are kept
# as-is; the x_is_weekend flag marks them red for manual correction.
# On success a parameter snapshot is stored; x_schedule_stale compares
# against it to warn when the schedule is out of date.
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
    # snapshot MUST match the signature in the x_schedule_stale compute
    sig = '|'.join([
        str(order.x_payment_type or ''),
        str(round(order.x_first_tranche_pct or 0.0, 4)),
        str(round(order.x_schedule_pct or 0.0, 4)),
        str(order.x_first_payment_date or ''),
        str(order.x_schedule_start_date or ''),
        str(order.x_schedule_interval or 1),
        str(order.x_project_end_date or ''),
        str(round(order.amount_total or 0.0, 2)),
    ])
    order['x_schedule_snapshot'] = sig
'@
$actionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) @{
    name = "FIGUREBI: გრაფიკის გენერაცია"; model_id = $saleModelId; state = "code"; code = $actionCode
}
Write-Host "server action updated id=$actionId"

# 3. view: alert banner + hidden helper fields
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
$saleFormViewId = (Invoke-Odoo "ir.model.data" "check_object_reference" @("sale", "view_order_form"))[1]
Ensure-Record "ir.ui.view" @(, @("name", "=", "sale.order.form.figurebi.installment")) @{
    name = "sale.order.form.figurebi.installment"; model = "sale.order"; type = "form"
    inherit_id = $saleFormViewId; mode = "extension"; arch_base = $arch
} | Out-Null
Write-Host "view updated"

# 4. e2e test on a temp order
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$soId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"; x_first_tranche_pct = 10.0; x_schedule_pct = 10.0
    x_first_payment_date = "2026-09-15"; x_schedule_start_date = "2026-10-15"
    x_schedule_interval = 1; x_project_end_date = "2027-12-30"
}))
Invoke-Odoo "ir.actions.server" "run" @(, @($actionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$r1 = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_schedule_stale"))
Write-Host ("after generate, stale = " + ($r1 | ConvertTo-Json -Depth 3))
Invoke-Odoo "sale.order" "write" @(@($soId), @{x_first_tranche_pct = 15.0}) | Out-Null
$r2 = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_schedule_stale"))
Write-Host ("after pct change, stale = " + ($r2 | ConvertTo-Json -Depth 3))
Invoke-Odoo "ir.actions.server" "run" @(, @($actionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$r3 = Invoke-Odoo "sale.order" "read" @(@($soId), @("x_schedule_stale"))
Write-Host ("after regenerate, stale = " + ($r3 | ConvertTo-Json -Depth 3))
Invoke-Odoo "sale.order" "unlink" @(, @($soId)) | Out-Null
Write-Host "test SO removed"
Write-Host "STALE WARNING DONE"
