from odoo import models


class StockPicking(models.Model):
    """Validating a unit's delivery flips it to sold on the plan.

    The Sold button on the order already refreshes vk_state, but a delivery
    can also be validated straight from Inventory -- this hook catches that
    path so the selector never shows a written-off flat as reserved.
    """

    _inherit = 'stock.picking'

    def button_validate(self):
        res = super().button_validate()
        templates = self.move_ids.mapped(
            'product_id.product_tmpl_id').filtered('vk_is_unit')
        if templates:
            templates._compute_vk_state()
        return res
