# -*- coding: utf-8 -*-
# Keep this file plain ASCII and BOM-free (a BOM here stops the registry).
{
    'name': "Price Matrix",
    'summary': "Stage pricing per unit type: the team's price matrix as an "
               "editable table, no developer needed to change it",
    'description': """
Price Matrix
============

The developer's price matrix, exactly as the sales team keeps it in Excel:
one row per unit type (block - view class - layout), with the total number
of units, how many are sold, and three sale stages, each a quantity and a
price per square metre. The current price is the price of the stage the
sales have reached: the first N units go at stage 1, the next N at stage 2,
the rest at stage 3.

Everything is a record. The team edits quantities and prices in the table
itself and adds or removes types; nothing is hardcoded. The side parameters
of the sheet (balcony percentage, parking price, commercial price) sit on
the matrix header.

First step: the sheet's own columns and nothing more. Automatic sold counts
from the units, the "next stage in N sales" column and writing the current
price onto the units are the next steps and are documented in the README.
    """,
    'author': "Vertikali",
    'category': 'Sales/CRM',
    'version': '19.0.13.0.2',
    'license': 'LGPL-3',

    # Its own app, its own menu, its own group -- but the matrix is built
    # from the units, which live in vertikali (project, building, view,
    # layout, state).
    'depends': ['vertikali', 'mail'],

    'data': [
        'security/groups.xml',
        'security/ir.model.access.csv',
        'data/states.xml',
        'data/layouts.xml',
        'views/price_matrix_views.xml',
        'views/vertikali_option_views.xml',
    ],

    'assets': {
        'web.assets_backend': [
            'vertikali_price_matrix/static/src/scss/price_matrix.scss',
        ],
    },

    'installable': True,
    'application': True,
    'auto_install': False,
}
