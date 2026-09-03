﻿# Replaces the numeric interval with a periodicity dropdown (like the sample):
# "once a month / every 2 months / ..." placed on its own row under the header
# cards. Generation and the stale signature switch to it. View v13. Idempotent.
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

# 1. periodicity selection field
$perFieldId = Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_periodicity")) @{
    model_id = $saleModelId; name = "x_periodicity"; state = "manual"
    field_description = "გადახდის პერიოდულობა"; ttype = "selection"
}
$selVals = @(@("1", "თვეში ერთხელ"), @("2", "ორ თვეში ერთხელ"), @("3", "სამ თვეში ერთხელ"), @("6", "ექვს თვეში ერთხელ"), @("12", "წელიწადში ერთხელ"))
$seq = 1
foreach ($sv in $selVals) {
    Ensure-Record "ir.model.fields.selection" @(@("field_id", "=", $perFieldId), @("value", "=", $sv[0])) @{
        field_id = $perFieldId; value = $sv[0]; name = $sv[1]; sequence = $seq
    } | Out-Null
    $seq++
}
Invoke-Odoo "ir.default" "set" @("sale.order", "x_periodicity", "1") | Out-Null
Write-Host "periodicity field ok (id=$perFieldId)"

# 2. generation action (canonical v5): interval from periodicity
$genCode = @'
# Generates the installment schedule. Structure: first tranche ($/% synced) +
# equal installments of the remainder + final payment ($/% synced) on its own
# date (x_final_payment_date; empty = the 15th of the completion month).
# Interval comes from the periodicity dropdown. Weekend dates stay red.
for order in records:
    total = order.amount_total
    if total <= 0:
        raise UserError("ჯამური ფასი უნდა იყოს 0-ზე მეტი — ჯერ დაამატეთ ობიექტი შეკვეთის ხაზებში.")
    if not order.x_first_payment_date:
        raise UserError("შეავსეთ პირველი გადახდის თარიღი.")
    ptype = order.x_payment_type or 'installment'
    order.x_installment_line_ids.unlink()
    vals_list = []
    if ptype == 'full_payment':
        vals_list.append({'x_order_id': order.id, 'x_number': 1, 'x_date': order.x_first_payment_date, 'x_amount': total})
    elif ptype == 'bank_loan':
        # Excel-style split: co-participation (client) + loan amount (bank)
        first_amt = round(order.x_first_tranche_amount or 0.0, 2)
        if first_amt < 0 or first_amt > total:
            raise UserError("თანამონაწილეობა 0-სა და ჯამურ ფასს შორის უნდა იყოს.")
        loan = round(total - first_amt, 2)
        num = 1
        if first_amt > 0.005:
            vals_list.append({'x_order_id': order.id, 'x_number': num, 'x_date': order.x_first_payment_date, 'x_amount': first_amt})
            num += 1
        if loan > 0.005:
            vals_list.append({'x_order_id': order.id, 'x_number': num, 'x_date': order.x_bank_transfer_date or order.x_first_payment_date, 'x_amount': loan})
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
        interval = int(order.x_periodicity or order.x_schedule_interval or 1)
        if interval < 1:
            raise UserError("გადახდის პერიოდულობა არასწორია.")
        cap = datetime.date(order.x_project_end_date.year, order.x_project_end_date.month, 15)
        bdate = order.x_final_payment_date or cap
        if bdate > order.x_project_end_date:
            raise UserError("ბოლო შენატანის თარიღი (%s) პროექტის დასრულების თარიღზე (%s) გვიან ვერ იქნება." % (bdate, order.x_project_end_date))
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
                raise UserError("თარიღების მიხედვით გრაფიკში შენატანი ვერ თავსდება — შეამოწმეთ თარიღები/პერიოდულობა.")
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
        str(order.x_periodicity or order.x_schedule_interval or 1),
        str(order.x_schedule_months or 0),
        str(order.x_final_payment_date or ''),
        str(order.x_bank_transfer_date or ''),
        str(order.x_project_end_date or ''),
        str(round(order.amount_total or 0.0, 2)),
    ])
    order['x_schedule_snapshot'] = sig
'@
$genActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) @{
    name = "FIGUREBI: გრაფიკის გენერაცია"; model_id = $saleModelId; state = "code"; code = $genCode
}
Write-Host "generation action updated (v5)"

# 3. stale compute: same signature
$staleCompute = @'
for r in self:
    sig = '|'.join([
        str(r.x_payment_type or ''),
        str(round(r.x_first_tranche_amount or 0.0, 2)),
        str(round(r.x_final_balloon_amount or 0.0, 2)),
        str(r.x_first_payment_date or ''),
        str(r.x_schedule_start_date or ''),
        str(r.x_periodicity or r.x_schedule_interval or 1),
        str(r.x_schedule_months or 0),
        str(r.x_final_payment_date or ''),
        str(r.x_bank_transfer_date or ''),
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
    depends = "x_payment_type,x_first_tranche_amount,x_final_balloon_amount,x_first_payment_date,x_schedule_start_date,x_periodicity,x_schedule_months,x_final_payment_date,x_bank_transfer_date,x_project_end_date,amount_total,x_schedule_snapshot,x_installment_line_ids.x_amount"
    compute = $staleCompute
} | Out-Null
Write-Host "stale compute updated"

# 4. view v13: periodicity row under the header cards; interval removed from UI
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
    <page string="გადახდის კალკულატორი" name="installment_schedule">
      <field name="x_schedule_stale" invisible="1"/>
      <field name="x_schedule_snapshot" invisible="1"/>
      <field name="x_has_weekend" invisible="1"/>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;">
        <div class="figurebi_card" style="flex: 1 1 180px; background: #f2f4ff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">დილი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="name" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #f2f4ff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">უძრავი ქონების № / მ²</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_object_ref" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #f2f4ff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">საწყისი კვ.მ ღირებულება</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_price_per_m2" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #f2f4ff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">საწყისი ჯამური ღირებულება</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_initial_total" readonly="1" nolabel="1"/></div>
        </div>
      </div>
      <div style="border-bottom: 2px solid #d1d5db; margin: 0 0 16px 0;"></div>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;">
        <div class="figurebi_card" style="flex: 0 1 calc(25% - 11px); background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">გადახდის ტიპი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_payment_type" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 0 1 calc(25% - 11px); background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;" invisible="x_payment_type != 'installment'">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">გადახდის პერიოდულობა</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_periodicity" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 0 1 calc(25% - 11px); background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;" invisible="x_payment_type != 'installment'">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">გადანაწილების ვადა (თვე)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_schedule_months" nolabel="1" placeholder="ცარიელი = დასრულებამდე"/></div>
        </div>
      </div>
      <div class="alert alert-warning" role="alert" invisible="not x_schedule_stale">
        ⚠️ გრაფიკი მოძველებულია — პარამეტრები ან თანხა შეიცვალა გენერაციის შემდეგ. დააჭირეთ „გრაფიკის გენერაციას" თავიდან.
      </div>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;">
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ფასდაკლება / ფასნამატი (%)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_discount_pct" nolabel="1"/></div>
        </div>        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ფასდაკლება / ფასნამატი კვ.მ ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_discount_per_m2" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ფასდაკლება / ფასნამატი სრული ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_discount_total" nolabel="1"/></div>
        </div>

        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">საბოლოო კვ.მ ფასი ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_final_price_per_m2" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">საბოლოო ფასი ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="amount_total" readonly="1" nolabel="1"/></div>
        </div>
      </div>
      <div class="figurebi_section" style="font-weight: 700; font-size: 14px; color: #374151; margin: 8px 0 10px; border-bottom: 2px solid #d1d5db; padding-bottom: 6px;">შენატანები და თარიღები</div>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;">
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">პირველადი შენატანის თარიღი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_first_payment_date" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;" invisible="x_payment_type != 'installment'">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">პირველადი შენატანი ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_first_tranche_amount" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;" invisible="x_payment_type != 'installment'">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">პირველადი შენატანი (%)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_first_tranche_pct" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;" invisible="x_payment_type != 'installment'">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">განვადების დაწყების თარიღი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_schedule_start_date" nolabel="1"/></div>
        </div>
      </div>
            <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;" invisible="x_payment_type != 'bank_loan'">
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">თანამონაწილეობა ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_first_tranche_amount" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">თანამონაწილეობა (%)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_first_tranche_pct" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">სესხის თანხა ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_bank_loan_amount" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">სესხის ჩარიცხვის თარიღი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_bank_transfer_date" nolabel="1" placeholder="ცარიელი = იმავე დღეს"/></div>
        </div>
      </div>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;" invisible="x_payment_type != 'installment'">
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">გრაფიკის ბოლო შენატანი (ავტო)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_schedule_end_date" readonly="1" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ბოლო შენატანი ($)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_final_balloon_amount" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ბოლო შენატანი (%)</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_final_balloon_pct" nolabel="1"/></div>
        </div>
        <div class="figurebi_card" style="flex: 1 1 180px; background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">ბოლო გადახდის თარიღი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_final_payment_date" nolabel="1" placeholder="ცარიელი = დასრულების თვის 15"/></div>
        </div>
        </div>
      <div class="figurebi_header" style="display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 16px;" invisible="x_payment_type != 'installment'">
        <div class="figurebi_card" style="flex: 0 1 calc(25% - 11px); background: #ffffff; border: 1px solid #d9defc; border-radius: 10px; padding: 10px 14px;">
          <div class="figurebi_label" style="font-size: 11px; color: #6b7280; margin-bottom: 4px;">პროექტის დასრულების თარიღი</div>
          <div class="figurebi_value" style="font-weight: 700; font-size: 15px; color: #2743a6;"><field name="x_project_end_date" nolabel="1"/></div>
        </div>
      </div>
      <group>
        <group string="დამატებითი პარამეტრები" invisible="x_payment_type != 'installment'">
          <label for="x_schedule_pct" string="გრაფიკით გადაიხდის"/>
          <div class="o_row">
            <field name="x_schedule_pct" class="oe_inline" readonly="1"/>
            <span>% =</span>
            <field name="x_schedule_amount" class="oe_inline" readonly="1"/>
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
Write-Host "view updated (v13)"

# 5. test: generation with periodicity=2 (every 2 months)
$prodId = [int]@(Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", "APAR/I/512"))))[0]
$partnerId = [int]@(Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", "გიორგი მაისურაძე (ტესტი)"))))[0]
$tmpId = [int](Invoke-Odoo "sale.order" "create" @(, @{
    partner_id = $partnerId
    order_line = @(, @(0, 0, @{product_id = $prodId; tax_ids = @(, @(6, 0, @()))}))
    x_payment_type = "installment"; x_first_tranche_pct = 10.0; x_final_balloon_pct = 80.0
    x_first_payment_date = "2026-09-01"; x_schedule_start_date = "2026-09-15"
    x_periodicity = "2"; x_project_end_date = "2027-09-30"
}))
Invoke-Odoo "ir.actions.server" "run" @(, @($genActionId)) @{context = @{active_model = "sale.order"; active_id = $tmpId; active_ids = @($tmpId)}} | Out-Null
$lines = @(Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $tmpId)), @("x_number", "x_date", "x_amount")) @{order = "x_number"})
$sum = 0
foreach ($l in $lines) { $sum += $l.x_amount; "{0}`t{1}`t{2}" -f $l.x_number, $l.x_date, $l.x_amount }
"rows=$($lines.Count) sum=$sum (expect 2-month gaps)"
Invoke-Odoo "sale.order" "unlink" @(, @($tmpId)) | Out-Null
"cleanup done; PERIODICITY DONE"
