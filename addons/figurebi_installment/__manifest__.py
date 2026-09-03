# -*- coding: utf-8 -*-
{
    "name": "FIGUREBI გადახდის კალკულატორი",
    "summary": "განვადების გრაფიკი, ინვოისები და CRM-განაწილება დეველოპერული გაყიდვებისთვის",
    "description": """
Real-estate installment calculator for developer sales:
- Payment calculator tab on quotations (installment / bank loan / full payment)
- First tranche and final payment enterable as both $ and % (live sync)
- Discount / markup in %, $ per m2 or total $ (live sync to the line's Disc.%)
- Schedule generation with weekend highlighting, one-click Monday fix (purple),
  guards on Send/Confirm/invoicing while red dates remain
- One draft invoice per installment with correct due dates
- Client-facing PDF of the schedule, Georgian quotation email template
- Apartment area auto-fills the ordered quantity
- CRM leads auto-assigned to managers by language (configurable in Settings)
    """,
    "version": "19.0.2.3.1",
    "author": "FIGUREBI",
    "license": "LGPL-3",
    "category": "Sales",
    "application": True,
    "depends": ["sale_management", "crm"],
    "data": [
        "security/ir.model.access.csv",
        "views/sale_order_views.xml",
        "views/product_views.xml",
        "views/res_config_settings_views.xml",
        "report/installment_report.xml",
        "data/product_data.xml",
        "data/mail_template_data.xml",
    ],
    "assets": {
        "web.assets_backend": [
            "figurebi_installment/static/src/scss/figurebi.scss",
        ],
    },
}
