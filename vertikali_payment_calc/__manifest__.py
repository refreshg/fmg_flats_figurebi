{
    'name': "განვადების კალკულატორი",
    'summary': "Instalment schedules for property sales, priced in dollars",
    'description': """
Instalment Calculator
=====================

Works out what a buyer pays and when: a deposit, a run of instalments and a
closing payment, against a flat's price.

**Schedule types** are records, not code. The team writes 10/20/70 the way it
says it, with the discount or markup that goes with it, and files a type away
as inactive when it stops being offered.

**A discount is quoted four ways** -- as a percentage or as a flat sum,
against the price per square metre or against the whole flat -- because all
four are in use and none is a rewording of another. One function applies it,
shared by the calculation and by the check that holds a standard schedule to
its type, so the two can never come to different answers.

**Several calculations, one schedule.** A salesperson tries 10/20/70 against
30/0/70, twelve months against six; each is kept, so the conversation can be
revisited rather than recomputed from memory. Exactly one per deal is marked
as the real schedule, and marking a second clears the first.

Standalone. It needs Sales and CRM and nothing else. Where the estate module
``vertikali`` is installed it reads a flat's area and metre price from it;
where it is not, it works from the list price alone.
    """,
    'author': "Vertikali",
    'category': 'Sales/CRM',
    'version': '19.0.1.2.0',
    'license': 'LGPL-3',

    # Deliberately short. Everything the calculator needs from an estate
    # module is read defensively, so this installs on a database that has no
    # such module at all.
    'depends': ['product', 'crm'],

    'data': [
        'security/ir.model.access.csv',
        'data/currency_data.xml',
        'data/payment_plan_data.xml',
        'views/payment_views.xml',
        'views/crm_lead_views.xml',
    ],

    'assets': {
        'web.assets_backend': [
            'vertikali_payment_calc/static/src/scss/payment_calc.scss',
        ],
    },

    'installable': True,
    'application': False,
    'auto_install': False,
}
