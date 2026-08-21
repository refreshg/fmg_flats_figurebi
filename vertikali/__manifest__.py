{
    'name': "ვერტიკალი — Real Estate Units",
    'summary': "Apartment inventory and visual unit selector for developers",
    'description': """
Vertikali — Real Estate Sales
=============================

Manages apartment inventory for property developers as standard Odoo products,
with a visual unit selector (facade -> floor -> unit) for the sales team.

Built standard-first: units are ``product.template`` records, the sales flow is
the stock CRM opportunity -> quotations -> sales order chain. Only the
apartment-specific fields and the visual selector are custom.
    """,
    'author': "Vertikali",
    'category': 'Sales',
    'version': '19.0.1.0.0',
    'license': 'LGPL-3',

    # crm/sale_crm give us the opportunity -> multiple quotations flow (D6),
    # stock gives per-unit availability. All verified installed on the target DB.
    'depends': [
        'base',
        'product',
        'sale_management',
        'crm',
        'sale_crm',
        'stock',
        'mail',
    ],

    'data': [
        'security/ir.model.access.csv',
        'views/product_template_views.xml',
        'views/menus.xml',
    ],

    'installable': True,
    'application': True,
}
