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
    'version': '19.0.1.3.0',
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
        'views/vertikali_layout_views.xml',
        'views/vertikali_view_views.xml',
        'views/menus.xml',
        # Sample building. Loaded as ordinary data because this database runs
        # without demo data (base.demo is False), and it is marked noupdate so
        # edits to the sample survive later upgrades. Remove this line once
        # real inventory replaces it.
        'data/demo_building_a.xml',
    ],

    'assets': {
        'web.assets_backend': [
            'vertikali/static/src/scss/view_selector.scss',
            'vertikali/static/src/js/view_selector.js',
            'vertikali/static/src/xml/view_selector.xml',
        ],
    },

    'installable': True,
    'application': True,
}
