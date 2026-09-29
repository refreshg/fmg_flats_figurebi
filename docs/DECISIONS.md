<!-- last-synced: 2026-09-15, commit: faac26e -->
# Architecture Decision Records

### D-1: Calculator lives on sale.order, not crm.lead
Date: 2026-08-27 · Context: price/discount/qty live on quotations; CRM converts to SO standardly.
Decision: all calculator fields/logic on sale.order. Rejected: CRM-side calculator (would duplicate pricing). Consequence: lead→quote flow unchanged.

### D-2: One flat = one product; qty = area (m²); unit price = price per m²
Date: 2026-08-27 · Decision: standard pricing math gives the total; x_area autofills qty. Rejected: one product per project with variants. Consequence: main-line convention (`_figurebi_main_line` = first non-display line) for per-m² figures.

### D-3: x_ field naming kept in the Python module
Date: 2026-09-01 · Context: staging was built first as manual x_ records over RPC (SaaS had no module option). Decision: module reuses identical x_ names so views/PDF/docs stay word-for-word portable. Rejected: clean `figurebi_` prefix. Consequence: module can never be installed on a DB with the manual fields.

### D-4: Weekend dates are flagged, not auto-shifted
Date: 2026-08-27 (user override of Excel's +2d) · Decision: red rows + one-click fix button (purple mark) + hard guard on Send/Confirm/invoices; manual edit clears purple. Rejected: silent auto-shift (Excel behavior). Consequence: manager stays in control of dates.

### D-5: Discount via the standard line discount field, precision raised to 6
Date: 2026-09-03 · Context: 10.7896% was silently computed as 10.79. Decision: Decimal Accuracy „Discount" = 6, all pct derivations round(…,6), pct card shows 4 decimals; sync dampers compare in currency (±0.011), not %. Rejected: adjusting price_unit instead of discount. Consequence: fresh-DB prerequisite (precision + Discounts group).

### D-6: Live sync via onchange, RPC durability via inverse on the two "final" fields only
Date: 2026-09-02 · Decision: computed-editable (compute+inverse+store) x_final_total / x_final_price_per_m2; each with its OWN compute method (a shared method left the sibling stale — Odoo protects all fields of one compute during inverse). Consequence: plain RPC writes to %/$ discount fields do not resync lines (known, documented).

### D-7: Last schedule row always absorbs rounding; balloon has its own row/date
Date: 2026-08-27 · Decision: n equal ROUND(…,2) installments, last schedule row takes the cents, balloon row on x_final_payment_date (default: 15th of project-end month). Consequence: sum is exactly amount_total, verified against the Excel reference.

### D-8: CRM routing by create/write override, not Rule-Based Assignment
Date: 2026-08-28 (plan approved by user) · Context: standard assignment is periodic and balance-based. Decision: immediate deterministic assignment on create/lang change; manual third-party assignee respected; managers configurable in Settings. Russian excluded by user decision.

### D-9: Standalone draft invoices, not linked to sale order lines
Date: 2026-08-27 · Decision: one draft out_invoice per schedule row (due = row date, origin = order name); accountant posts from Accounting. Rejected: sale advance-payment wizard (cannot follow the schedule). Consequence: SO invoice_status is untouched; duplicate-guard by origin.

### D-10: Two distributions from one repo
Date: 2026-09-01 · Decision: real Python module for on-premise/odoo.sh + XML/CSV-only `figurebi_installment_data` for SaaS Import Module. Consequence: data twin lags behind and is still untested.

### D-11: Local-only git; secrets externalized
Date: 2026-09-03 (user answers) · Decision: local repo, no remote yet; all credentials only in git-ignored SECRETS.local.md; scripts read `$env:FIGUREBI_STAGING_KEY`; zips git-ignored (rebuilt on Linux — Windows zips carry backslash paths).

### D-12: History pushed to the company repo as branch `figurebi` (supersedes "no remote" in D-11)
Date: 2026-09-03 (user request, same day) · Context: refreshg/fmg_flats_figurebi holds the vertikali flats module at repo root with its own CLAUDE.md/research/deploy scripts; merging two workspaces into main would collide. Decision: our full history lives on branch `figurebi` of that repo; main untouched. Consequence: the two lines can be merged later only after agreeing a shared layout; the repo is currently public — recommended to make private.

### D-13: 4 decimal places on all calculator % and $ fields; real money stays at cents
Date: 2026-09-03 (user request: "ყველგან 4 ციფრი წერტილის მერე, პროცენტისაც და თანხებისაც") · Decision: `digits=(16,4)` on every calculator input/display field, sync math rounds to 4. Deliberately kept at 2: schedule rows, invoices, loan amount, PMT, amount_total, snapshot signature (real payments have no sub-cent). x_bank_rate left untouched (14.0000 would be noise).

### D-14: A schedule installment in the balloon's month is folded away
Date: 2026-09-03 (user rule) · Context: schedule Dec 13 + balloon Dec 15 made the client pay twice in the final month. Decision: `_installment_vals` drops the colliding installment; remaining ones grow to cover the same schedule amount. Rejected: merging it into the balloon (old Excel-era behavior). Consequence: with spread N, the actual installment count can be N−1.

### D-15: Dates display a worded month with the year always visible (custom widget)
Date: 2026-09-03, revised same day · Context: Odoo 19's humanized date display omits the current year ("Oct 5"); the numeric option ("10/05/2026") shows the year but the user then asked for a worded month too. Decision: custom field widget `figurebi_date` (extends web's DateTimeField, `getFormattedValue` → luxon DATE_MED without the current-year omission) on all 7 date fields → "Oct 5, 2026". Supersedes the interim numeric option (v19.0.2.3.1 → v19.0.2.4.0).

### D-16: Sales are VAT-free (Excel parity)
Date: 2026-09-03 · Context: flats carried the default 15% tax; x_final_total (tax-incl.) diverged from the Excel reference. Decision: taxes cleared on all 126 flat products + open quote lines (RPC); the user then zeroed the default tax record itself (account.tax id=1 → "0%"/0.0), so new products stay harmless. Consequence: restore that record to 15 if real VAT is ever needed.

### D-17: Balloon-month rule ported into vertikali_payment_calc, shipped on main
Date: 2026-09-11 (user chose via question) · Context: the CRM "განვადების კალკულატორი" dialog turned out to live in a separate module `vertikali_payment_calc` (folder `C:\Users\dchac\Desktop\vs code\vertikali_payment_calc`, previously in no git repo), not in vertikali. Decision: the fold rule goes into the owning module's `_schedule_rows` (mirrors D-14), and the whole module was committed to the company repo's `main` (d6aeab3) — its first commit. Rejected: cross-module override from figurebi_installment; server-only patch. Consequence: the other developer must be told main gained a module; deploy to the server was still pending as of 2026-09-15 (SSH ban).

### D-18: Interim UI changes via manual ir.ui.view records while SSH is down
Date: 2026-09-15 · Context: file deploys need SSH; sshd rejected this workstation (fail2ban ban persisted across restarts via its sqlite db). Decision: the flat column on sale lists shipped as manual view records (ids 2448/2449) over RPC — the staging-era mechanism; flat FILTERING needed nothing (standard "Product" search entry already covers `order_line.product_id`). Consequence: fold into module views and delete 2448/2449 on the next SSH deploy. Lesson recorded: PS1 with Georgian must be UTF-8 BOM even in scratchpad — a BOM-less script mojibake'd the column label once.
