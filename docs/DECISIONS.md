<!-- last-synced: 2026-09-03, commit: 6f3b0f2 -->
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
