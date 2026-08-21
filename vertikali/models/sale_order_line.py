from odoo import api, models


class SaleOrderLine(models.Model):
    """Keeps unit availability in step with the sales pipeline.

    vk_state cannot use a normal dependency chain: product.product has no
    sale-line one2many, and sale.order.line.product_template_id is a non-stored
    related field. So the recompute is triggered from here, on every write that
    can change which unit is held by which order.
    """

    _inherit = 'sale.order.line'

    def _vk_affected_templates(self):
        return self.mapped('product_id.product_tmpl_id').filtered('vk_is_unit')

    def _vk_refresh_units(self, templates):
        templates = templates.exists()
        if templates:
            templates._compute_vk_state()

    @api.model_create_multi
    def create(self, vals_list):
        lines = super().create(vals_list)
        lines._vk_refresh_units(lines._vk_affected_templates())
        return lines

    def write(self, vals):
        # A line can move to another product, so refresh both sides.
        before = self._vk_affected_templates()
        res = super().write(vals)
        self._vk_refresh_units(before | self._vk_affected_templates())
        return res

    def unlink(self):
        templates = self._vk_affected_templates()
        res = super().unlink()
        self._vk_refresh_units(templates)
        return res


class SaleOrder(models.Model):
    """Confirming or cancelling an order flips its units in one step.

    sale.order.line.state is related to order_id.state, and changing it on the
    order does not necessarily run write() on each line -- so the order-level
    transitions are hooked explicitly.
    """

    _inherit = 'sale.order'

    def _vk_refresh_units(self):
        templates = self.order_line.mapped(
            'product_id.product_tmpl_id').filtered('vk_is_unit')
        if templates:
            templates._compute_vk_state()

    def action_confirm(self):
        res = super().action_confirm()
        self._vk_refresh_units()
        return res

    def action_cancel(self):
        res = super().action_cancel()
        self._vk_refresh_units()
        return res

    def action_draft(self):
        res = super().action_draft()
        self._vk_refresh_units()
        return res

    def action_quotation_sent(self):
        res = super().action_quotation_sent()
        self._vk_refresh_units()
        return res
