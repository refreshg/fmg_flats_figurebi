﻿# CRM language-based lead assignment (demo): EN leads -> EN test manager,
# everything else (KA / empty / other) -> KA test manager. A manager chosen
# deliberately by the operator (different from themselves) is never overridden.
# Idempotent.
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

# 3. tests
$enLangId = [int]@(Invoke-Odoo "res.lang" "search" @(, @(, @("code", "=", "en_US"))))[0]
$kaLangId = [int]@(Invoke-Odoo "res.lang" "search" @(, @(, @("code", "=", "ka_GE"))))[0]
function Test-Lead($label, $vals, $expectUserId) {
    $id = [int](Invoke-Odoo "crm.lead" "create" @(, $vals))
    $r = Invoke-Odoo "crm.lead" "read" @(@($id), @("user_id"))
    $got = if ($r.user_id) { [int]$r.user_id[0] } else { 0 }
    $status = if ($got -eq $expectUserId) { "OK" } else { "FAIL (got $($r.user_id[1]))" }
    Write-Host ("{0}: {1}" -f $label, $status)
    return $id
}
$ids = @()
$ids += Test-Lead "T1 lang=en -> EN" @{name = "ტესტ ლიდი EN"; lang_id = $enLangId} $enUserId
$ids += Test-Lead "T2 lang=ka -> KA" @{name = "ტესტ ლიდი KA"; lang_id = $kaLangId} $kaUserId
$ids += Test-Lead "T3 no lang -> KA" @{name = "ტესტ ლიდი ცარიელი"} $kaUserId
$ids += Test-Lead "T4 manual pick respected" @{name = "ტესტ ლიდი ხელით"; lang_id = $enLangId; user_id = 17} 17
# T5: manual reassign after creation sticks (no lang change)
Invoke-Odoo "crm.lead" "write" @(@([int]$ids[0]), @{user_id = 17}) | Out-Null
$r5 = Invoke-Odoo "crm.lead" "read" @(@([int]$ids[0]), @("user_id"))
Write-Host ("T5 manual reassign sticks: " + $(if ([int]$r5.user_id[0] -eq 17) { "OK" } else { "FAIL" }))
Invoke-Odoo "crm.lead" "unlink" @(, @($ids)) | Out-Null
Write-Host "test leads removed; CRM LANG ASSIGN DONE"
