# -*- coding: utf-8 -*-
from odoo import fields, models


class ProductTemplate(models.Model):
    _inherit = "product.template"

    x_area = fields.Float(
        string="ფართი (მ²)",
        help="Total area in m2; auto-fills the quantity on sale order lines.",
    )
