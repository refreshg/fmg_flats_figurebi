﻿# Adds a client-facing PDF report "განვადების გრაფიკი" to sale orders:
# a QWeb template + ir.actions.report bound to the Print menu. Idempotent.
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

# 4. test: download the PDF for the demo order via an authenticated session
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01054"))))[0]
$authBody = @{jsonrpc = "2.0"; method = "call"; params = @{db = $db; login = "admin"; password = $key}} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$base/web/session/authenticate" -Method Post -ContentType "application/json" -Body $authBody -SessionVariable ws | Out-Null
$pdfPath = Join-Path $env:TEMP "figurebi-test-schedule.pdf"
Invoke-WebRequest -Uri "$base/report/pdf/$templateKey/$soId" -WebSession $ws -OutFile $pdfPath
$bytes = [System.IO.File]::ReadAllBytes($pdfPath)
$magic = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
Write-Host ("PDF test: magic='$magic', size=$($bytes.Length) bytes, saved to $pdfPath")
if ($magic -ne "%PDF") { throw "Downloaded file is not a PDF!" }
Write-Host "PDF REPORT DONE"
