<!-- last-synced: 2026-09-03, commit: 345d4d9 -->
# Technical spec — figurebi_installment (Odoo 19)

Module `figurebi_installment` v19.0.2.3.2, depends: `sale_management`, `crm`.
All calculator % and $ input/display fields carry `digits=(16, 4)` (user rule: 4 decimals
everywhere on the tab); real money — schedule rows, invoices, PMT, amount_total — stays at cents.
Field/model names keep the `x_` prefix for parity with the manual (RPC-built) staging setup.

## Data model

### x_figurebi_installment_line — NEW model (`models/installment_line.py`)
`_order = "x_order_id, x_number, id"`

| field | type | required | compute | notes |
|---|---|---|---|---|
| x_order_id | Many2one sale.order | yes | | ondelete=cascade, indexed |
| x_number | Integer | yes | | row number |
| x_date | Date | yes | | payment date |
| x_amount | Float | | | payment amount |
| x_balance | Float | | `_compute_balance` | amount_total − paid up to this x_number |
| x_is_weekend | Boolean | | `_compute_is_weekend` | weekday ≥ 5 |
| x_auto_fixed | Boolean | | | purple mark; cleared by `write()` on manual x_date change unless ctx `figurebi_autofix` |

### sale.order — MODIFIED (`models/sale_order.py`)
Stored input fields:

| field | type | notes |
|---|---|---|
| x_payment_type | Selection installment/bank_loan/full_payment | default installment |
| x_periodicity | Selection '1','2','3','6','12' | months between payments, default '1' |
| x_schedule_months | Integer | 0/empty = auto (spread until project end) |
| x_first_payment_date, x_schedule_start_date, x_project_end_date | Date | |
| x_final_payment_date | Date | balloon date; empty = 15th of project-end month |
| x_bank_transfer_date | Date | bank_loan only; empty = first payment date |
| x_first_tranche_pct / x_first_tranche_amount | Float | default 10.0 / synced |
| x_final_balloon_pct / x_final_balloon_amount | Float | default 80.0 / synced |
| x_discount_pct | Float digits (16,4) | discount/markup %, negative = markup |
| x_discount_per_m2, x_discount_total | Float | $ forms of the discount |
| x_bank_rate / x_bank_term_months | Float/Integer | defaults 14.0 / 120 |
| x_installment_line_ids | One2many x_figurebi_installment_line | |
| x_schedule_snapshot | Char, copy=False | signature at generation time |

Computed fields:

| field | compute | stored | notes |
|---|---|---|---|
| x_object_ref, x_price_per_m2, x_initial_total | `_compute_header` | no | main-line ref, per-m² price, pre-discount total |
| x_final_price_per_m2 | `_compute_final_price_per_m2` + inverse | yes, readonly=False | editable; reverse-computes % |
| x_final_total | `_compute_final_total` + inverse | yes, readonly=False | editable; reverse-computes % |
| x_schedule_pct, x_schedule_amount | `_compute_schedule_part` | no | remainder 100 − tranche% − balloon% |
| x_bank_loan_amount, x_bank_pmt_reference | `_compute_bank` | no | loan principal, annuity PMT |
| x_schedule_end_date | `_compute_schedule_end` | no | max(line dates) **excluding the balloon row**, or forecast from start+months |
| x_has_weekend, x_schedule_stale, x_installment_invoice_count | own computes | no | |

Key helpers: `_figurebi_main_line` (first non-display line), `_figurebi_unit_area`
(x_area → vertikali vk_area_total → qty), `_figurebi_price_per_m2`, `_figurebi_gross`,
`_figurebi_gross_incl_tax` (per-line de-discounted price_total), `_figurebi_pct_from_final_total`
(round 6), `_figurebi_final_total_reached` (±0.011 currency damper), `_figurebi_signature`.

### Other inherits
- product.template: `x_area` Float — flat area in m²
- sale.order.line: onchange product_id → `product_uom_qty = x_area`
- crm.lead: create/write(lang_id) → `_figurebi_assign_by_lang` (managers from
  ir.config_parameter `figurebi.en_manager_id` / `figurebi.ka_manager_id`; ctx guard `figurebi_crm_assign`)
- res.config.settings: `figurebi_en_manager_id`, `figurebi_ka_manager_id` ↔ those params

## Business logic

| rule | trigger | action | AC |
|---|---|---|---|
| %↔$ tranche/balloon sync | onchange pcts/amounts/order_line | recompute counterpart, % wins on total change | AC-2 |
| discount 5-way sync | onchange x_discount_pct / per_m2 / total / final_m2 / final_total; inverses on the two final fields (RPC-safe) | derive pct (round 6), write all sync fields + every line's `discount`; skip when target already reached (±0.011) | AC-3 |
| pct ≤ 100 guard | `_apply_discount_pct` | UserError above 100% | AC-3 |
| schedule generation | button → `action_generate_schedule` | tranche row + n equal rows (last schedule row absorbs cents) + balloon row on its date; saves snapshot; bank_loan → 2 rows; full_payment → 1 row | AC-1, AC-8 |
| balloon-month fold | inside `_installment_vals` | a schedule installment landing in the balloon's own month is dropped; remaining installments grow to cover the schedule amount (one payment per final month) | user rule 2026-09-03, no AC yet |
| weekend marking | compute on x_date | red decoration | AC-4 |
| weekend autofix | button → `action_fix_weekends` | Sat+2/Sun+1, sets x_auto_fixed (purple) with ctx figurebi_autofix | AC-4 |
| weekend guard | `sale.order.write` on state→sent/sale; also inside invoice generation | UserError listing red dates | AC-4 |
| invoice generation | button → `action_generate_invoices`, state must be 'sale' | one draft out_invoice per line, due=x_date, origin=order name, INSTALLMENT-FEE product, no payment term; duplicate-guard by origin | AC-5 |
| smart button | `action_view_installment_invoices` | act_window on account.move by origin | AC-5 |
| stale warning | `_compute_stale` | signature or sum mismatch (>0.01) vs snapshot → alert | AC-10 |
| final date sync | onchange months/start/periodicity (installment) | x_final_payment_date = start + count×interval | — |
| validations | generation | final date > last installment, ≤ project end; N-month spread must fit before project end | AC-1 |
| area autofill | line onchange product_id | qty = x_area | AC-9 |
| CRM routing | lead create / lang_id write | en* → EN manager, else KA; manual third-party assignee respected | AC-7 |

## Views / UI
| view | type | xml id | notes |
|---|---|---|---|
| Quotation tab „გადახდის კალკულატორი" | form inherit sale.view_order_form | `figurebi_installment.view_order_form_installment` | header/info cards (inline styles), discount row, payments section, buttons (generate / fix weekends / invoices), schedule list with decorations (danger=weekend, primary=auto_fixed), smart button, stale alert; all 7 date fields use `options="{'numeric': true}"` so the year is always shown (Odoo 19 hides the current year otherwise) |
| Product form area field | form inherit | `figurebi_installment.product_template_form_area` | x_area on product.template |
| Settings FIGUREBI section | form inherit | `figurebi_installment.res_config_settings_view_form` | two manager fields |
| PDF report | qweb template + report action | `figurebi_installment.report_installment`, `figurebi_installment.action_report_installment` | qweb-pdf on sale.order Print menu |
| Email template | record override | `sale.email_template_edi_sale` | Georgian subject/body; attaches installment PDF |
| SCSS | asset web.assets_backend | `static/src/scss/figurebi.scss` | purple/red row styling only; layout styles are inline in the arch |

## Security
- `security/ir.model.access.csv`: `access_figurebi_installment_line_salesman` —
  model_x_figurebi_installment_line, group `sales_team.group_sale_salesman`, CRUD 1/1/1/1
- No record rules; buttons rely on standard sale access

## Integrations
None external. Outbound: email via overridden `sale.email_template_edi_sale`;
PDF via wkhtmltopdf. Ops-level: deployment/upgrade over SSH + JSON-RPC (see CLAUDE.md Commands).

## Migration / data
- `data/product_data.xml`: service product „განვადების შენატანი" (INSTALLMENT-FEE), xml id `product_installment_fee`
- Install prerequisites on a fresh DB: enable Discounts (`group_discount_per_so_line`),
  set Decimal Accuracy „Discount" = 6 — the module does not set either itself
- MUST NOT be installed on a DB that already carries the manual x_ fields (communapp staging) — ir.model.fields unique clash
- Upgrades are in-place (`button_immediate_upgrade`); no data migrations so far

## Tests (manual — user tests functionally in UI)
| AC | manual check |
|---|---|
| AC-1 | reference case 70,000 → 7,000 + equal rows + balloon; sum exact; PMT 869.49 |
| AC-2 | type 10% → $ appears; type $ → % appears; change qty → $ follows % |
| AC-3 | type 10.7896 → line Disc.% 10.7896, total to the cent; type final total → % derived; negative % raises total |
| AC-4 | Saturday date red; button → Monday purple; manual edit clears purple; Confirm blocked while red |
| AC-5 | invoices blocked on draft; after Confirm — one draft invoice per row, due dates match, sum matches |
| AC-6 | Print → Georgian PDF; Send → email with 2 PDFs |
| AC-7 | set managers in Settings; en lead → EN manager; ka/empty → KA; manual assignee kept |
| AC-8 | bank_loan 20% → 2 rows, PMT on loan amount |
| AC-9 | pick product → qty = area immediately |
| AC-10 | change % after generation → yellow alert; regenerate → gone |
| (no AC) balloon-month | balloon on 12/13, last installment would be 12/05 → that row is dropped, remaining rows grow, sum exact |
| (no AC) 4 decimals | type 10.7896% or 1,762.4340$ → stored/shown unchanged |
| (no AC) years | all date cards and the schedule date column show the year (e.g. 10/05/2026) |

## Traceability
| AC | models/fields | verified |
|---|---|---|
| AC-1 | sale.order action_generate_schedule, x_figurebi_installment_line | on-prem 2026-09-02 ✅ |
| AC-2 | x_first_tranche_*, x_final_balloon_* onchanges | staging ✅ / on-prem UI pending user |
| AC-3 | x_discount_*, x_final_total, x_final_price_per_m2, Discount precision 6 | on-prem 2026-09-03 ✅ (RPC) |
| AC-4 | x_is_weekend, x_auto_fixed, write guard, action_fix_weekends | on-prem 2026-09-02 ✅ |
| AC-5 | action_generate_invoices, x_installment_invoice_count | on-prem 2026-09-02 ✅ |
| AC-6 | report_installment, email_template_edi_sale | on-prem PDF ✅; email staging ✅ |
| AC-7 | crm_lead._figurebi_assign_by_lang, res.config.settings | staging ✅; on-prem unconfigured |
| AC-8 | x_bank_transfer_date, x_bank_loan_amount, _compute_bank | staging ✅ |
| AC-9 | sale_order_line._onchange_product_area, product.template.x_area | staging ✅ |
| AC-10 | x_schedule_snapshot, x_schedule_stale | staging ✅ |
