# -*- coding: utf-8 -*-
"""qty_sold / qty_reserved became computed from the units (D-68). An existing
column is not recomputed on upgrade, so the lines that have units are
brought up to date here once; the dependency keeps them so afterwards."""
from odoo import SUPERUSER_ID, api


def migrate(cr, version):
    if not version:
        return
    env = api.Environment(cr, SUPERUSER_ID, {})
    Line = env['vertikali.price.matrix.line']
    lines = Line.search([('unit_ids', '!=', False)])
    for fname in ('qty_sold', 'qty_reserved'):
        env.add_to_compute(Line._fields[fname], lines)
    env.flush_all()
