# ============================================================================
# FIGUREBI გადახდის კალკულატორი — სრული დაყენება on-premise სერვერზე
# გაშვება:  PowerShell-ში:  powershell -ExecutionPolicy Bypass -File .\setup-onprem.ps1
# სკრიპტი გაშვებისას გკითხავთ ადმინის ლოგინს/პაროლს. ხანგრძლივობა: ~3-5 წუთი.
# უსაფრთხოა ხელახლა გაშვება (idempotent - არსებულს აახლებს).
# ============================================================================
$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$global:ONPREM_LOGIN = Read-Host "Odoo ადმინის ლოგინი (Enter = admin)"
if (-not $global:ONPREM_LOGIN) { $global:ONPREM_LOGIN = "admin" }
$sec = Read-Host "Odoo ადმინის პაროლი" -AsSecureString
$global:ONPREM_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
Write-Host "სამიზნე: https://46.233.53.183:2223 / ბაზა: odoo / მომხმარებელი: $global:ONPREM_LOGIN"

# --- prerequisite: make sure required Odoo modules are installed -------------
function Invoke-PreRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "https://46.233.53.183:2223/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$preUid = Invoke-PreRaw "common" "authenticate" @("odoo", $global:ONPREM_LOGIN, $global:ONPREM_PASSWORD, @{})
if (-not $preUid) { throw "ავტორიზაცია ვერ მოხერხდა — შეამოწმეთ ლოგინი/პაროლი" }
Write-Host "ავტორიზაცია OK (uid=$preUid)"
foreach ($m in @("base_automation", "sale_management", "crm")) {
    $mods = @(Invoke-PreRaw "object" "execute_kw" @("odoo", $preUid, $global:ONPREM_PASSWORD, "ir.module.module", "search_read", @(, @(, @("name", "=", $m))), @{fields = @("state")}))
    if ($mods.Count -eq 0) { throw "მოდული $m ვერ მოიძებნა სერვერზე" }
    if ($mods[0].state -ne "installed") {
        Write-Host "ვაყენებ საჭირო მოდულს: $m ..."
        Invoke-PreRaw "object" "execute_kw" @("odoo", $preUid, $global:ONPREM_PASSWORD, "ir.module.module", "button_immediate_install", @(, @([int]$mods[0].id))) | Out-Null
        Write-Host "$m დაყენდა"
    } else { Write-Host "$m უკვე დგას" }
}


Write-Host ''
Write-Host '=================== deploy-jsonrpc.ps1 ==================='
# Deploys the FIGUREBI installment calculator to Odoo staging via JSON-RPC,
# using manual models/fields, a server action, and an inherited view.
# No git / module upload required. Idempotent: re-running updates existing records.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$login = $global:ONPREM_LOGIN
$key = $global:ONPREM_PASSWORD

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


Write-Host ''
Write-Host '=================== add-test-data.ps1 ==================='
# Adds realistic test data to staging: apartment products (m² uom, price per m²),
# test customers, and a ready demo quotation with a generated schedule.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error | ConvertTo-Json -Depth 10) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}
function Get-XmlId($module, $name) {
    return (Invoke-Odoo "ir.model.data" "check_object_reference" @($module, $name))[1]
}

# enable Disc.% column on order lines (standard setting)
$settingsId = [int](Invoke-Odoo "res.config.settings" "create" @(, @{group_discount_per_so_line = $true}))
Invoke-Odoo "res.config.settings" "execute" @(, @($settingsId)) | Out-Null
Write-Host "discount setting enabled"

# m² unit of measure
$m2Id = Get-XmlId "uom" "product_uom_square_meter"
Write-Host "m2 uom id=$m2Id"

# apartment products: code, name, area, price per m2
$apartments = @(
    @("APAR/I/512",  "ბინა I/512 (52.1 მ²)",  52.1, 1300.97),
    @("APAR/I/513",  "ბინა I/513 (45.3 მ²)",  45.3, 1350.00),
    @("APAR/I/812",  "ბინა I/812 (68.4 მ²)",  68.4, 1250.00),
    @("APAR/II/101", "ბინა II/101 (75.0 მ²)", 75.0, 1400.00),
    @("COM/I/1",     "კომერციული I/1 (120 მ²)", 120.0, 1800.00)
)
$prodIds = @{}
foreach ($a in $apartments) {
    $found = Invoke-Odoo "product.product" "search" @(, @(, @("default_code", "=", $a[0])))
    if ($found.Count -gt 0) {
        $prodId = [int]$found[0]
        Invoke-Odoo "product.product" "write" @(@($prodId), @{name = $a[1]; list_price = $a[3]; uom_id = $m2Id; description_sale = "ჯამური ფართი: $($a[2]) მ²"}) | Out-Null
    } else {
        $prodId = [int](Invoke-Odoo "product.product" "create" @(, @{
            name = $a[1]; default_code = $a[0]; type = "service"
            list_price = $a[3]; uom_id = $m2Id
            description_sale = "ჯამური ფართი: $($a[2]) მ²"
            taxes_id = @(, @(6, 0, @()))
        }))
    }
    $prodIds[$a[0]] = $prodId
    Write-Host ("product {0} id={1}" -f $a[0], $prodId)
}

# test customers
$customers = @("გიორგი მაისურაძე (ტესტი)", "ნინო კაპანაძე (ტესტი)")
$partnerIds = @()
foreach ($c in $customers) {
    $found = Invoke-Odoo "res.partner" "search" @(, @(, @("name", "=", $c)))
    if ($found.Count -gt 0) { $partnerIds += [int]$found[0] } else {
        $partnerIds += [int](Invoke-Odoo "res.partner" "create" @(, @{name = $c; phone = "+995 555 000 000"}))
    }
}
Write-Host "customers: $($partnerIds -join ', ')"

# demo quotation: apartment 512, qty = area, 5% discount, installment params filled
$soVals = @{
    partner_id = $partnerIds[0]
    order_line = @(, @(0, 0, @{
        product_id = $prodIds["APAR/I/512"]
        product_uom_qty = 52.1
        price_unit = 1300.97
        discount = 5.0
        tax_ids = @(, @(6, 0, @()))
    }))
    x_payment_type = "installment"
    x_first_tranche_pct = 10.0
    x_schedule_pct = 10.0
    x_first_payment_date = "2026-09-15"
    x_schedule_start_date = "2026-10-15"
    x_schedule_interval = 1
    x_project_end_date = "2027-12-30"
}
$soId = [int](Invoke-Odoo "sale.order" "create" @(, $soVals))
$actionId = [int](Invoke-Odoo "ir.actions.server" "search" @(, @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია"))))[0]
Invoke-Odoo "ir.actions.server" "run" @(, @($actionId)) @{context = @{active_model = "sale.order"; active_id = $soId; active_ids = @($soId)}} | Out-Null
$so = Invoke-Odoo "sale.order" "read" @(@($soId), @("name", "amount_total"))
Write-Host ("demo quotation: " + ($so | ConvertTo-Json -Depth 3))
$lines = Invoke-Odoo "x_figurebi_installment_line" "search_read" @(@(, @("x_order_id", "=", $soId)), @("x_number", "x_date", "x_amount", "x_is_weekend")) @{order = "x_number"}
foreach ($l in $lines) {
    $wk = if ($l.x_is_weekend) { "  <-- WEEKEND" } else { "" }
    Write-Host ("{0}`t{1}`t{2}{3}" -f $l.x_number, $l.x_date, $l.x_amount, $wk)
}
Write-Host "TEST DATA DONE"


Write-Host ''
Write-Host '=================== add-stale-warning.ps1 ==================='
# Adds a "schedule is stale" warning: generation stores a parameter snapshot;
# a computed flag compares current params/totals against it and the view shows
# a yellow alert when they diverge. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-pdf-report.ps1 ==================='
# Adds a client-facing PDF report "განვადების გრაფიკი" to sale orders:
# a QWeb template + ir.actions.report bound to the Print menu. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. QWeb template
$templateKey = "x_figurebi.report_installment"
$arch = @'
<t t-name="x_figurebi.report_installment">
  <t t-call="web.html_container">
    <t t-foreach="docs" t-as="doc">
      <t t-call="web.external_layout">
        <div class="page">
          <t t-set="cur" t-value="doc.currency_id.symbol or ''"/>
          <t t-set="ptype" t-value="doc.x_payment_type or 'installment'"/>
          <h2 style="margin-bottom:4px;">განვადების გრაფიკი</h2>
          <p style="color:#666; margin-top:0;">
            შეთავაზება <span t-field="doc.name"/> ·
            თარიღი: <span t-field="doc.date_order" t-options='{"widget": "date"}'/>
          </p>

          <div class="row mt-3">
            <div class="col-6">
              <strong>კლიენტი</strong><br/>
              <span t-field="doc.partner_id.name"/><br/>
              <span t-if="doc.partner_id.phone" t-field="doc.partner_id.phone"/>
            </div>
            <div class="col-6">
              <strong>გაყიდვების მენეჯერი</strong><br/>
              <span t-field="doc.user_id.name"/>
            </div>
          </div>

          <h5 class="mt-4">ობიექტი</h5>
          <table class="table table-sm">
            <thead>
              <tr>
                <th>დასახელება</th>
                <th class="text-end">ფართი/რაოდ.</th>
                <th class="text-end">ერთ. ფასი</th>
                <th class="text-end">ფასდ.%</th>
                <th class="text-end">თანხა</th>
              </tr>
            </thead>
            <tbody>
              <tr t-foreach="doc.order_line.filtered(lambda l: not l.display_type)" t-as="ol">
                <td><span t-field="ol.product_id.name"/></td>
                <td class="text-end"><span t-esc="'%g' % ol.product_uom_qty"/> <span t-field="ol.product_uom_id.name"/></td>
                <td class="text-end"><span t-esc="'{:,.2f}'.format(ol.price_unit)"/></td>
                <td class="text-end"><span t-esc="'%g' % (ol.discount or 0)"/></td>
                <td class="text-end"><span t-esc="'{:,.2f}'.format(ol.price_total)"/></td>
              </tr>
            </tbody>
          </table>
          <p class="text-end"><strong>ჯამური ღირებულება: <span t-esc="'{:,.2f}'.format(doc.amount_total)"/> <t t-esc="cur"/></strong></p>

          <h5 class="mt-4">გადახდის პირობები</h5>
          <table class="table table-sm" style="width:60%;">
            <tr>
              <td>გადახდის ტიპი</td>
              <td><t t-esc="dict(installment='შიდა განვადება', bank_loan='ბანკის სესხი', full_payment='ერთიანი გადახდა').get(ptype, '')"/></td>
            </tr>
            <t t-if="ptype == 'installment'">
              <tr>
                <td>პირველი ტრანში (<t t-esc="'%g' % (doc.x_first_tranche_pct or 0)"/>%)</td>
                <td><t t-esc="'{:,.2f}'.format(doc.x_first_tranche_amount or 0)"/> <t t-esc="cur"/></td>
              </tr>
              <tr>
                <td>გრაფიკით გადასახდელი (<t t-esc="'%g' % (doc.x_schedule_pct or 0)"/>%)</td>
                <td><t t-esc="'{:,.2f}'.format(doc.x_schedule_amount or 0)"/> <t t-esc="cur"/></td>
              </tr>
              <tr t-if="(doc.x_final_balloon_amount or 0) &gt; 0.01">
                <td>ბოლო გადახდა (ნაშთი)</td>
                <td><t t-esc="'{:,.2f}'.format(doc.x_final_balloon_amount or 0)"/> <t t-esc="cur"/></td>
              </tr>
            </t>
          </table>

          <h5 class="mt-4">გადახდების გრაფიკი</h5>
          <table class="table table-sm">
            <thead>
              <tr>
                <th style="width:10%;">#</th>
                <th>თარიღი</th>
                <th class="text-end">თანხა</th>
              </tr>
            </thead>
            <tbody>
              <tr t-foreach="doc.x_installment_line_ids.sorted(key=lambda l: l.x_number)" t-as="il">
                <td><span t-esc="il.x_number"/></td>
                <td><span t-field="il.x_date"/></td>
                <td class="text-end"><span t-esc="'{:,.2f}'.format(il.x_amount)"/> <t t-esc="cur"/></td>
              </tr>
            </tbody>
            <tfoot>
              <tr>
                <td/>
                <td class="text-end"><strong>ჯამი</strong></td>
                <td class="text-end"><strong><t t-esc="'{:,.2f}'.format(sum(doc.x_installment_line_ids.mapped('x_amount')))"/> <t t-esc="cur"/></strong></td>
              </tr>
            </tfoot>
          </table>

          <p t-if="ptype == 'installment' and (doc.x_bank_pmt_reference or 0) &gt; 0" style="color:#666; font-size:12px;">
            * დარჩენილი თანხის საბანკო დაფინანსების შემთხვევაში სავარაუდო ყოველთვიური შენატანი:
            <t t-esc="'{:,.2f}'.format(doc.x_bank_pmt_reference)"/> <t t-esc="cur"/>
            (<t t-esc="'%g' % (doc.x_bank_rate or 0)"/>%, <t t-esc="doc.x_bank_term_months or 0"/> თვე).
          </p>
          <p style="color:#666; font-size:12px;">
            დოკუმენტი საინფორმაციო ხასიათისაა და არ წარმოადგენს ხელშეკრულებას.
          </p>
        </div>
      </t>
    </t>
  </t>
</t>
'@

$viewId = Ensure-Record "ir.ui.view" @(, @("key", "=", $templateKey)) @{
    name = "FIGUREBI installment report"; type = "qweb"; key = $templateKey; arch_base = $arch
}
Write-Host "qweb view id=$viewId"

# 2. xml id so the report can resolve the template by name
$imd = @(Invoke-Odoo "ir.model.data" "search" @(, @(@("module", "=", "x_figurebi"), @("name", "=", "report_installment"))))
if ($imd.Count -eq 0) {
    Invoke-Odoo "ir.model.data" "create" @(, @{module = "x_figurebi"; name = "report_installment"; model = "ir.ui.view"; res_id = $viewId}) | Out-Null
    Write-Host "xmlid created"
} else {
    Invoke-Odoo "ir.model.data" "write" @(@($imd[0]), @{res_id = $viewId}) | Out-Null
    Write-Host "xmlid updated"
}

# 3. report action bound to sale.order's Print menu
$saleModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]
$reportId = Ensure-Record "ir.actions.report" @(, @("report_name", "=", $templateKey)) @{
    name = "განვადების გრაფიკი"
    model = "sale.order"
    report_type = "qweb-pdf"
    report_name = $templateKey
    print_report_name = "'განვადება - %s' % (object.name)"
    binding_model_id = $saleModelId
    binding_type = "report"
}
Write-Host "report action id=$reportId"



Write-Host ''
Write-Host '=================== add-invoice-generation.ps1 ==================='
# Adds "generate invoices from schedule": a service product for installment fees,
# a server action creating one draft customer invoice per schedule line (due date =
# line date), and a button on the schedule tab. Then runs it on the demo order.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== update-quotation-email.ps1 ==================='
# Updates the standard "Sales: Send Quotation" email template with the Georgian
# commercial-offer text (dynamic order number, apartment name, salesperson) and
# attaches the installment schedule PDF alongside the quotation. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
function Invoke-Odoo($model, $method, $methodArgs, $kwargs = @{}) {
    return Invoke-OdooRaw "object" "execute_kw" @($db, $script:uid, $key, $model, $method, $methodArgs, $kwargs)
}

# 1. resolve the standard quotation template
$tmplId = [int](Invoke-Odoo "ir.model.data" "check_object_reference" @("sale", "email_template_edi_sale"))[1]
Write-Host "mail template id=$tmplId"

# 2. new subject + body (inline qweb t-out placeholders)
$subject = "კომერციული შეთავაზება № {{ object.name }}"
$body = @'
<div style="margin:0px; padding:0px; font-size:13px;">
    <p>გამარჯობა,</p>
    <p>
        გიგზავნით კომერციულ შეთავაზებას № <t t-out="object.name"/><t t-if="object.order_line.filtered(lambda l: not l.display_type)[:1].product_id">,
        <t t-out="object.order_line.filtered(lambda l: not l.display_type)[:1].product_id.name"/>-ის შეძენასთან დაკავშირებით</t>.
    </p>
    <p>
        გთხოვთ, გაეცნოთ თანდართულ დოკუმენტს. შეთავაზების პირობებზე თანხმობის შემთხვევაში,
        გთხოვთ, დაგვიდასტუროთ პასუხად.
    </p>
    <p>
        დამატებითი კითხვების შემთხვევაში, მზად ვართ მოგაწოდოთ დეტალური ინფორმაცია.
    </p>
    <p>
        პატივისცემით,<br/>
        <t t-out="object.user_id.name or ''"/><br/>
        <t t-out="object.company_id.name or ''"/>
    </p>
</div>
'@
Invoke-Odoo "mail.template" "write" @(@($tmplId), @{subject = $subject; body_html = $body}) | Out-Null
Write-Host "subject+body updated"

# 3. attach the installment schedule PDF in addition to existing attachments
$reportId = [int]@(Invoke-Odoo "ir.actions.report" "search" @(, @(, @("report_name", "=", "x_figurebi.report_installment"))))[0]
Invoke-Odoo "mail.template" "write" @(@($tmplId), @{report_template_ids = @(, @(4, $reportId))}) | Out-Null
Write-Host "schedule PDF attached (report id=$reportId)"



Write-Host ''
Write-Host '=================== add-weekend-guard-smartbutton.ps1 ==================='
# 1) Blocks SO confirmation and invoice generation while the schedule contains
#    weekend (red) dates. 2) Adds a stat smart-button on the SO showing how many
#    installment invoices were issued, opening the filtered list. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-weekend-autofix.ps1 ==================='
# Adds the "fix weekend dates" button: shifts every red (weekend) schedule date
# to Monday (Sat +2, Sun +1) and marks those rows purple (x_auto_fixed) so the
# manager can still adjust specific ones manually; a manual date edit clears the
# purple mark. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-invoice-state-guard.ps1 ==================='
# Restricts invoice generation to CONFIRMED sales orders: the button is hidden
# on quotations and the server action refuses to run until state == 'sale'.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-manual-months.ps1 ==================='
# Adds x_schedule_months: optional manual spread duration for the installment
# part. Empty = automatic (until project end, as before); N = exactly N months
# of installments, balloon still due at the completion cap. Updates the stale
# signature in BOTH places. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. the new field
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_schedule_months")) @{
    model_id = $saleModelId; name = "x_schedule_months"; state = "manual"
    field_description = "გადანაწილების ვადა (თვე)"; ttype = "integer"
    help = "How many months to spread the schedule part over. Empty/0 = automatic, until project completion."
} | Out-Null
Write-Host "field ok"

# 2. generation action (canonical): manual-months branch + months in the snapshot
$genCode = @'
# Generates the installment schedule for the selected sale order(s).
# Mirrors the company's Excel calculator (sheet "100"):
# first tranche + N-monthly installments + final remainder (balloon).
# If x_schedule_months is set, the installment part spreads over exactly that
# many months (balloon still due at the completion cap); otherwise dates run
# automatically until the 15th of the completion month. Weekend dates are kept
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
        has_balloon = (first_pct + sched_pct) < 99.999
        months = int(order.x_schedule_months or 0)
        dates = []
        if months > 0:
            # manual spread: exactly N months of installments
            count = max(1, months // interval)
            for k in range(count):
                dates.append(order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=k * interval))
            if dates[-1] >= cap or dates[-1] > order.x_project_end_date:
                raise UserError("გადანაწილების ვადა (%s თვე) სცდება პროექტის დასრულებას — ბოლო შენატანი %s-ზე გვიან ვერ იქნება." % (months, cap))
            if has_balloon:
                # balloon is still due at the completion cap
                dates.append(cap)
        else:
            # automatic: run until the completion cap (as before)
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
        str(order.x_schedule_months or 0),
        str(order.x_project_end_date or ''),
        str(round(order.amount_total or 0.0, 2)),
    ])
    order['x_schedule_snapshot'] = sig
'@
$genActionId = Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: გრაფიკის გენერაცია")) @{
    name = "FIGUREBI: გრაფიკის გენერაცია"; model_id = $saleModelId; state = "code"; code = $genCode
}
Write-Host "generation action updated"

# 3. stale compute: same signature (with months)
$staleCompute = @'
for r in self:
    sig = '|'.join([
        str(r.x_payment_type or ''),
        str(round(r.x_first_tranche_pct or 0.0, 4)),
        str(round(r.x_schedule_pct or 0.0, 4)),
        str(r.x_first_payment_date or ''),
        str(r.x_schedule_start_date or ''),
        str(r.x_schedule_interval or 1),
        str(r.x_schedule_months or 0),
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
    depends = "x_payment_type,x_first_tranche_pct,x_schedule_pct,x_first_payment_date,x_schedule_start_date,x_schedule_interval,x_schedule_months,x_project_end_date,amount_total,x_schedule_snapshot,x_installment_line_ids.x_amount"
    compute = $staleCompute
} | Out-Null
Write-Host "stale compute updated"

# 4. view v7: add the field after the interval
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
          <field name="x_schedule_months" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულებამდე"/>
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
Write-Host "view updated (v7)"



Write-Host ''
Write-Host '=================== add-schedule-end-date.ps1 ==================='
# Adds x_schedule_end_date: read-only computed date of the LAST schedule line —
# the exact date the client finishes paying. Shown under the schedule start date.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. computed field: date of the last schedule line
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_schedule_end_date")) @{
    model_id = $saleModelId; name = "x_schedule_end_date"; state = "manual"
    field_description = "გრაფიკის დასრულების თარიღი"; ttype = "date"; store = $false
    depends = "x_installment_line_ids.x_date,x_schedule_start_date,x_schedule_months,x_periodicity"
    compute = "for r in self:`n    dates = [d for d in r.x_installment_line_ids.mapped('x_date') if d]`n    if dates:`n        r['x_schedule_end_date'] = max(dates)`n    elif r.x_schedule_start_date and int(r.x_schedule_months or 0) > 0:`n        interval = int(r.x_periodicity or 1)`n        count = max(1, int(r.x_schedule_months) // interval)`n        r['x_schedule_end_date'] = r.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=(count - 1) * interval)`n    else:`n        r['x_schedule_end_date'] = False"
    help = "The exact date of the client's final payment (last schedule line)."
} | Out-Null
Write-Host "field ok"

# 2. view v8: show it read-only under the schedule start date
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
          <field name="x_schedule_end_date" readonly="1"
                 invisible="x_payment_type != 'installment' or not x_installment_line_ids"/>
          <field name="x_schedule_interval" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_months" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულებამდე"/>
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
Write-Host "view updated (v8)"



Write-Host ''
Write-Host '=================== add-balance-column.ps1 ==================='
# Adds a running-balance column (ნაშთი) to the schedule list: order total minus
# everything paid up to and including the row. Read-only, computed.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

$lineModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "x_figurebi_installment_line"))))[0]

# 1. running balance field on the line
$balCompute = @'
for r in self:
    order = r.x_order_id
    paid = sum(l.x_amount or 0.0 for l in order.x_installment_line_ids if (l.x_number or 0) <= (r.x_number or 0))
    r['x_balance'] = round((order.amount_total or 0.0) - paid, 2)
'@
Ensure-Record "ir.model.fields" @(@("model_id", "=", $lineModelId), @("name", "=", "x_balance")) @{
    model_id = $lineModelId; name = "x_balance"; state = "manual"
    field_description = "ნაშთი"; ttype = "float"; store = $false
    depends = "x_amount,x_number,x_order_id.x_installment_line_ids.x_amount,x_order_id.amount_total"
    compute = $balCompute
    help = "Remaining balance after this payment."
} | Out-Null
Write-Host "balance field ok"

# 2. view v9: add the column
$saleModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "sale.order"))))[0]
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
          <field name="x_schedule_end_date" readonly="1"
                 invisible="x_payment_type != 'installment' or not x_installment_line_ids"/>
          <field name="x_schedule_interval" invisible="x_payment_type != 'installment'"/>
          <field name="x_schedule_months" invisible="x_payment_type != 'installment'"
                 placeholder="ცარიელი = დასრულებამდე"/>
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
Write-Host "view updated (v9)"



Write-Host ''
Write-Host '=================== add-paired-percents.ps1 ==================='
# Pairs each percentage with its amount on one row (tranche / schedule / final
# balloon) and adds the computed final-payment percent. View v10.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== rework-calculator-v2.ps1 ==================='
# Reworks the calculator to match the reference widget:
#  - first tranche and final payment enterable as BOTH $ and % (two-way sync)
#  - schedule part becomes the computed remainder (100% - first - final)
#  - final payment date manually enterable (empty = 15th of completion month)
#  - discount enterable in $ (per m2 or total) writing the line's Disc.%
# Updates generation action + stale signature (both places). View v11. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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


Write-Host ''
Write-Host '=================== add-header-cards.ps1 ==================='
# Adds the reference-style header cards to the schedule tab: deal no, object
# code + m2, initial price per m2, initial total. Styled like the sample widget.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-periodicity.ps1 ==================='
# Replaces the numeric interval with a periodicity dropdown (like the sample):
# "once a month / every 2 months / ..." placed on its own row under the header
# cards. Generation and the stale signature switch to it. View v13. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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



Write-Host ''
Write-Host '=================== add-discount-pct.ps1 ==================='
# Adds an enterable discount % that syncs both ways with the $ discount fields
# and the line's Disc.%: enter $ -> see %, enter % -> see $. Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. discount % field (stored, enterable)
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_discount_pct")) @{
    model_id = $saleModelId; name = "x_discount_pct"; state = "manual"
    field_description = "ფასდაკლება (%)"; ttype = "float"
} | Out-Null
Write-Host "pct field ok"

# 2. $ -> % automation (update existing action: also fills x_discount_pct)
$codeC = @'
# Discount entered in dollars (per m2 or total): translate to the line's Disc.%,
# mirror the other dollar field and show the resulting percent.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        gross = line.price_unit * line.product_uom_qty
        per_m2 = order.x_discount_per_m2 or 0.0
        total_d = order.x_discount_total or 0.0
        if per_m2 and abs(per_m2 * line.product_uom_qty - total_d) > 0.01:
            total_d = round(per_m2 * line.product_uom_qty, 2)
        elif total_d:
            per_m2 = round(total_d / line.product_uom_qty, 2)
        pct = round(total_d / gross * 100.0, 4) if gross else 0.0
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_total': total_d,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeC
} | Out-Null
Write-Host "dollar->pct action updated"

# 3. % -> $ automation (new)
$pctFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", "x_discount_pct"))))[0]
$autoD = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების %-ის სინქრონი")) @{
    name = "FIGUREBI: ფასდაკლების %-ის სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($pctFieldId))); active = $true
}
$codeD = @'
# Discount entered as a percent: write the line's Disc.% and fill both dollar fields.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        pct = order.x_discount_pct or 0.0
        if pct > 100:
            raise UserError("ფასდაკლება 100%-ს ვერ გადააჭარბებს (მინუსი = ფასნამატი).")
        gross = line.price_unit * line.product_uom_qty
        total_d = round(gross * pct / 100.0, 2)
        per_m2 = round(line.price_unit * pct / 100.0, 2)
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_total': total_d,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების %-ის სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების %-ის სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeD
    usage = "base_automation"; base_automation_id = $autoD
} | Out-Null
Write-Host "pct->dollar automation ok"



Write-Host ''
Write-Host '=================== fix-discount-priority.ps1 ==================='
# Splits the $-discount sync into two automations so the field the user just
# edited always wins: per-m2 trigger -> per-m2 is master; total trigger ->
# total is master. (Percent already has its own automation.) Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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
function Get-FieldId($name) {
    return [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", $name))))[0]
}

# C1: per-m2 changed -> per-m2 is master
$autoC1 = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონი")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_discount_per_m2")))); active = $true
}
$codeC1 = @'
# Per-m2 discount/markup changed: it is the master; recompute total, percent,
# and the line's Disc.%. Negative = markup.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        per_m2 = order.x_discount_per_m2 or 0.0
        total_d = round(per_m2 * line.product_uom_qty, 2)
        pct = round(per_m2 / line.price_unit * 100.0, 4)
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_total': total_d,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeC1
    usage = "base_automation"; base_automation_id = $autoC1
} | Out-Null
Write-Host "C1 (per-m2 master) ok"

# C2: total changed -> total is master
$autoC2 = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონი (სრული)")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონი (სრული)"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_discount_total")))); active = $true
}
$codeC2 = @'
# Total discount/markup changed: it is the master; recompute per-m2, percent,
# and the line's Disc.%. Negative = markup.
if not env.context.get('figurebi_disc'):
    for order in records:
        line = order.order_line.filtered(lambda l: not l.display_type)[:1]
        if not line or not line.price_unit or not line.product_uom_qty:
            continue
        gross = line.price_unit * line.product_uom_qty
        total_d = order.x_discount_total or 0.0
        per_m2 = round(total_d / line.product_uom_qty, 2)
        pct = round(total_d / gross * 100.0, 4) if gross else 0.0
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს.")
        line.write({'discount': pct})
        order.with_context(figurebi_disc=True).write({
            'x_discount_per_m2': per_m2,
            'x_discount_pct': pct,
        })
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ფასდაკლების სინქრონის მოქმედება (სრული)")) @{
    name = "FIGUREBI: ფასდაკლების სინქრონის მოქმედება (სრული)"; model_id = $saleModelId; state = "code"; code = $codeC2
    usage = "base_automation"; base_automation_id = $autoC2
} | Out-Null
Write-Host "C2 (total master) ok"



Write-Host ''
Write-Host '=================== add-bank-split.ps1 ==================='
# Splits the bank_loan type Excel-style: co-participation (client's own money,
# reuses the first-tranche $/% synced fields) + loan amount (bank transfer) on
# its own date. Adds bank-only cards, updates generation + PMT + stale
# signature (both places). Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. new fields
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_transfer_date")) @{
    model_id = $saleModelId; name = "x_bank_transfer_date"; state = "manual"
    field_description = "სესხის ჩარიცხვის თარიღი"; ttype = "date"
    help = "Empty = same day as the co-participation payment."
} | Out-Null
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_loan_amount")) @{
    model_id = $saleModelId; name = "x_bank_loan_amount"; state = "manual"
    field_description = "სესხის თანხა"; ttype = "float"; store = $false
    depends = "amount_total,x_first_tranche_amount,x_payment_type"
    compute = "for r in self:`n    r['x_bank_loan_amount'] = round((r.amount_total or 0.0) - (r.x_first_tranche_amount or 0.0), 2) if (r.x_payment_type or '') == 'bank_loan' else 0.0"
} | Out-Null
Write-Host "fields ok"

# 2. PMT: bank_loan -> loan amount; installment -> balloon amount
Ensure-Record "ir.model.fields" @(@("model_id", "=", $saleModelId), @("name", "=", "x_bank_pmt_reference")) @{
    model_id = $saleModelId; name = "x_bank_pmt_reference"; state = "manual"
    field_description = "საბანკო შენატანი (საცნობარო)"; ttype = "float"; store = $false
    depends = "amount_total,x_payment_type,x_first_tranche_amount,x_final_balloon_amount,x_bank_rate,x_bank_term_months"
    compute = "for r in self:`n    total = r.amount_total or 0.0`n    if (r.x_payment_type or '') == 'bank_loan':`n        p = total - (r.x_first_tranche_amount or 0.0)`n    else:`n        p = r.x_final_balloon_amount or 0.0`n    m = r.x_bank_term_months or 0`n    rate = (r.x_bank_rate or 0.0) / 100.0 / 12.0`n    if p <= 0 or m <= 0:`n        r['x_bank_pmt_reference'] = 0.0`n    elif rate:`n        r['x_bank_pmt_reference'] = round(p * rate / (1 - (1 + rate) ** -m), 2)`n    else:`n        r['x_bank_pmt_reference'] = round(p / m, 2)"
} | Out-Null
Write-Host "PMT compute updated"

Write-Host "BANK SPLIT PART 1 DONE (fields+PMT); view+generation patched via add-periodicity.ps1"


Write-Host ''
Write-Host '=================== add-final-date-sync.ps1 ==================='
# When spread months / schedule start / periodicity change on an installment
# order, auto-set the final payment date to one interval AFTER the last
# installment (Excel-like: balloon is the next date in the sequence).
# Typing the date directly still works (that write does not retrigger).
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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
function Get-FieldId($name) {
    return [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $saleModelId), @("name", "=", $name))))[0]
}

$autoE = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ბოლო გადახდის თარიღის სინქრონი")) @{
    name = "FIGUREBI: ბოლო გადახდის თარიღის სინქრონი"; model_id = $saleModelId; trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @((Get-FieldId "x_schedule_months"), (Get-FieldId "x_schedule_start_date"), (Get-FieldId "x_periodicity")))); active = $true
}
$codeE = @'
# Spread params changed: place the final (balloon) payment one interval after
# the last installment. Direct edits of the date itself do not retrigger this.
if not env.context.get('figurebi_final_sync'):
    for order in records:
        if (order.x_payment_type or 'installment') != 'installment':
            continue
        months = int(order.x_schedule_months or 0)
        if months > 0 and order.x_schedule_start_date:
            interval = int(order.x_periodicity or 1)
            count = max(1, months // interval)
            new_date = order.x_schedule_start_date + dateutil.relativedelta.relativedelta(months=count * interval)
            if order.x_final_payment_date != new_date:
                order.with_context(figurebi_final_sync=True).write({'x_final_payment_date': new_date})
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ბოლო გადახდის თარიღის სინქრონის მოქმედება")) @{
    name = "FIGUREBI: ბოლო გადახდის თარიღის სინქრონის მოქმედება"; model_id = $saleModelId; state = "code"; code = $codeE
    usage = "base_automation"; base_automation_id = $autoE
} | Out-Null
Write-Host "automation ok (id=$autoE)"



Write-Host ''
Write-Host '=================== add-crm-lang-assign.ps1 ==================='
# CRM language-based lead assignment (demo): EN leads -> EN test manager,
# everything else (KA / empty / other) -> KA test manager. A manager chosen
# deliberately by the operator (different from themselves) is never overridden.
# Idempotent.
$ErrorActionPreference = "Stop"
$base = "https://46.233.53.183:2223"
$db = "odoo"
$key = $global:ONPREM_PASSWORD

function Invoke-OdooRaw($service, $method, $callArgs) {
    $payload = @{jsonrpc = "2.0"; method = "call"; params = @{service = $service; method = $method; args = $callArgs}; id = (Get-Random)}
    $json = $payload | ConvertTo-Json -Depth 40
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $r = Invoke-RestMethod -Uri "$base/jsonrpc" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes
    if ($r.PSObject.Properties.Name -contains "error") { throw ($r.error.data.message) }
    return $r.result
}
$script:uid = Invoke-OdooRaw "common" "authenticate" @($db, $global:ONPREM_LOGIN, $key, @{})
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

# 1. test manager users (sales group, no invitation mail)
$salesGroupId = [int](Invoke-Odoo "ir.model.data" "check_object_reference" @("sales_team", "group_sale_salesman"))[1]
function Ensure-User($name, $login) {
    $found = @(Invoke-Odoo "res.users" "search" @(, @(, @("login", "=", $login))))
    if ($found.Count -gt 0) { return [int]$found[0] }
    return [int](Invoke-Odoo "res.users" "create" @(, @{
        name = $name; login = $login; group_ids = @(, @(4, $salesGroupId))
    }) @{context = @{no_reset_password = $true}})
}
$enUserId = Ensure-User "ელენე (ინგლისური)" "en.manager.test"
$kaUserId = Ensure-User "დავითი (ქართული)" "ka.manager.test"
Write-Host "managers: EN=$enUserId KA=$kaUserId"

# 2. automation on crm.lead (create + lang change)
$leadModelId = [int]@(Invoke-Odoo "ir.model" "search" @(, @(, @("model", "=", "crm.lead"))))[0]
$langFieldId = [int]@(Invoke-Odoo "ir.model.fields" "search" @(, @(@("model_id", "=", $leadModelId), @("name", "=", "lang_id"))))[0]
$autoId = Ensure-Record "base.automation" @(, @("name", "=", "FIGUREBI: ლიდის ენით განაწილება")) @{
    name = "FIGUREBI: ლიდის ენით განაწილება"
    model_id = $leadModelId
    trigger = "on_create_or_write"
    trigger_field_ids = @(, @(6, 0, @($langFieldId)))
    active = $true
}
$assignCode = @'
# Assigns the salesperson by the lead's language: en* -> EN manager, anything
# else (ka / empty / other) -> KA manager (default per user's decision).
# A salesperson deliberately chosen by the operator (someone other than the
# operator themselves) is respected and never overridden.
if not env.context.get('figurebi_crm_assign'):
    en_user = env['res.users'].search([('login', '=', 'en.manager.test')], limit=1)
    ka_user = env['res.users'].search([('login', '=', 'ka.manager.test')], limit=1)
    if en_user and ka_user:
        for lead in records:
            if lead.user_id and lead.user_id.id != env.uid and lead.user_id.id not in (en_user.id, ka_user.id):
                continue
            code = lead.lang_id.code or '' if lead.lang_id else ''
            target = en_user if code.startswith('en') else ka_user
            if lead.user_id.id != target.id:
                lead.with_context(figurebi_crm_assign=True).write({'user_id': target.id})
'@
Ensure-Record "ir.actions.server" @(, @("name", "=", "FIGUREBI: ლიდის ენით განაწილების მოქმედება")) @{
    name = "FIGUREBI: ლიდის ენით განაწილების მოქმედება"; model_id = $leadModelId; state = "code"; code = $assignCode
    usage = "base_automation"; base_automation_id = $autoId
} | Out-Null
Write-Host "automation ok (id=$autoId)"


Write-Host ""
Write-Host "============================================================"
Write-Host "  დაყენება დასრულდა! გახსენით Sales -> New Quotation და"
Write-Host "  ნახეთ ტაბი 'გადახდის კალკულატორი'."
Write-Host "============================================================"