<!-- last-synced: 2026-09-03, commit: 6f3b0f2 -->
# FIGUREBI გადახდის კალკულატორი (figurebi_installment)

Real-estate installment calculator on quotations: payment schedule generation with
weekend guards, per-installment draft invoices, client PDF, Georgian email, CRM lead
routing by language. Odoo **19** only.

- **Depends**: `sale_management`, `crm`
- **Install**: copy into an addons path, restart, Update Apps List, install — full
  walkthrough (Georgian): [`INSTALL_ON_PREMISE.md`](../../INSTALL_ON_PREMISE.md).
  Upgrade: bump `__manifest__.py` version, restart, `button_immediate_upgrade`.

## Configuration (required after install)
1. Settings → Sales → Pricing → **Discounts** ON (`group_discount_per_so_line`)
2. Developer mode → Technical → Decimal Accuracy → **Discount = 6**
3. Settings → CRM → FIGUREBI: EN/KA lead managers (stored as `figurebi.en_manager_id` / `figurebi.ka_manager_id`)
4. Company logo/details for the PDF and email; `wkhtmltopdf` on the server
5. On flat products: set unit = m², price = per m², fill **ფართი (მ²)** (`x_area`)

## Known limitations
- Live %↔$/discount sync runs on UI onchange; plain RPC writes to the %/$ fields do
  not resync lines (the two editable "final price" fields do work over RPC via inverse)
- Draft invoices are not linked to sale order lines — SO `invoice_status` is untouched
- Multi-line orders: per-m² figures follow the first non-display line only
- MUST NOT be installed on a database already carrying the manual `x_` fields
  (e.g. the communapp staging built by `scripts/`)

Docs: [`docs/PRD.md`](../../docs/PRD.md) · [`docs/SPEC.md`](../../docs/SPEC.md) ·
[`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) · [`docs/DECISIONS.md`](../../docs/DECISIONS.md) ·
[`docs/PLAN.md`](../../docs/PLAN.md)
