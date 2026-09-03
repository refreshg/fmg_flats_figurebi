﻿# Updates the standard "Sales: Send Quotation" email template with the Georgian
# commercial-offer text (dynamic order number, apartment name, salesperson) and
# attaches the installment schedule PDF alongside the quotation. Idempotent.
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

# 4. test-render on S01058
$soId = [int]@(Invoke-Odoo "sale.order" "search" @(, @(, @("name", "=", "S01058"))))[0]
$rendered = Invoke-Odoo "mail.template" "generate_email" @(@($tmplId), @($soId), @("subject", "body_html", "attachments"))
$r = $rendered."$soId"
Write-Host "SUBJECT: $($r.subject)"
Write-Host "BODY:"
Write-Host ($r.body_html)
$attNames = @(); foreach ($a in $r.attachments) { $attNames += $a[0] }
Write-Host "ATTACHMENTS: $($attNames -join '; ')"
Write-Host "EMAIL TEMPLATE DONE"
