# -*- coding: utf-8 -*-
from odoo import api, models


class SaleOrderLine(models.Model):
    _inherit = "sale.order.line"

    @api.onchange("product_id")
    def _onchange_product_area(self):
        # apartment area (m2) auto-fills the ordered quantity
        area = self.product_id.product_tmpl_id.x_area
        if area:
            self.product_uom_qty = area
