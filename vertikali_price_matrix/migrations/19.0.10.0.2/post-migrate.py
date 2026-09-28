# -*- coding: utf-8 -*-
"""No em dash in the layout names (user, 2026-09-26): data/layouts.xml is
noupdate, so "S — სტუდიო" stayed in the database after the file changed."""
from odoo import SUPERUSER_ID, api

DASH = '—'


def migrate(cr, version):
    if not version:
        return
    env = api.Environment(cr, SUPERUSER_ID, {})
    layouts = env['vertikali.price.matrix.layout'].with_context(active_test=False).search(
        [('name', 'like', DASH)])
    for layout in layouts:
        layout.name = layout.name.replace(DASH, '-')
