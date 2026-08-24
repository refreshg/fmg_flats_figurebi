from odoo import _, api, fields, models
from odoo.exceptions import UserError


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

    # The unit deal's own pipeline, riding on top of the standard order
    # states: reservation (confirmed, quant reserved), contract (papers
    # signed), sold (delivery validated, quant written off), cancelled.
    # Quotations have no stage on purpose -- a draft holds nothing.
    vk_stage = fields.Selection(
        selection=[
            ('reservation', "Reservation"),
            ('contract', "Contract"),
            ('sold', "Sold"),
            ('cancelled', "Cancelled"),
        ],
        string="Unit Stage",
        compute='_compute_vk_stage',
        store=True,
        index=True,
    )
    vk_contract_signed = fields.Boolean(
        string="Contract Signed", copy=False)
    vk_has_units = fields.Boolean(compute='_compute_vk_has_units')

    @api.depends('order_line.product_id')
    def _compute_vk_has_units(self):
        for order in self:
            order.vk_has_units = any(
                order.order_line.product_id.product_tmpl_id.mapped('vk_is_unit'))

    @api.depends('state', 'vk_contract_signed',
                 'order_line.qty_delivered', 'order_line.product_id')
    def _compute_vk_stage(self):
        for order in self:
            unit_lines = order.order_line.filtered(
                lambda l: l.product_id.product_tmpl_id.vk_is_unit)
            if not unit_lines:
                order.vk_stage = False
            elif order.state == 'cancel':
                order.vk_stage = 'cancelled'
            elif order.state != 'sale':
                order.vk_stage = False
            elif any(l.qty_delivered > 0 for l in unit_lines):
                order.vk_stage = 'sold'
            elif order.vk_contract_signed:
                order.vk_stage = 'contract'
            else:
                order.vk_stage = 'reservation'

    def _vk_refresh_units(self):
        templates = self.order_line.mapped(
            'product_id.product_tmpl_id').filtered('vk_is_unit')
        if templates:
            templates._compute_vk_state()

    def action_cancel(self):
        # Cancelling releases the unit, full stop. Odoo's own cancel only
        # unreserves; a delivery that was already validated (Mark Sold) keeps
        # the quant written off, and the flat would stay off the market
        # forever. So the units of every DONE delivery come back through a
        # validated return transfer.
        done_pickings = self.picking_ids.filtered(
            lambda p: p.state == 'done'
            and p.picking_type_id.code == 'outgoing'
            and any(m.product_id.product_tmpl_id.vk_is_unit
                    for m in p.move_ids))
        res = super().action_cancel()
        Return = self.env['stock.return.picking']
        for picking in done_pickings:
            wiz = Return.with_context(
                active_id=picking.id, active_model='stock.picking').create({})
            for line in wiz.product_return_moves:
                is_unit = line.product_id.product_tmpl_id.vk_is_unit
                line.quantity = line.move_id.product_uom_qty if is_unit else 0
            action = wiz.action_create_returns()
            ret = self.env['stock.picking'].browse(action['res_id'])
            for move in ret.move_ids:
                move.quantity = move.product_uom_qty
                move.picked = True
            ret.with_context(skip_backorder=True).button_validate()
        self._vk_refresh_units()
        return res

    def action_confirm(self):
        # The double-sale gate. Odoo happily confirms an order with no stock
        # -- the delivery just waits -- so availability is enforced here:
        # each unit's single quant must still be free (not reserved by
        # another confirmed order, not written off).
        for order in self:
            for line in order.order_line:
                tmpl = line.product_id.product_tmpl_id
                if not tmpl.vk_is_unit:
                    continue
                free = line.product_id.free_qty
                if free < line.product_uom_qty:
                    raise UserError(_(
                        "Unit %s is not available any more -- it is "
                        "reserved or sold on another order.",
                        tmpl.default_code or tmpl.name))
        res = super().action_confirm()
        self._vk_refresh_units()
        return res

    def action_vk_sign_contract(self):
        """Reservation -> Contract. A human milestone, so a manual button."""
        for order in self:
            if order.vk_stage != 'reservation':
                raise UserError(_(
                    "Only a reservation can move to Contract."))
        self.write({'vk_contract_signed': True})

    def action_vk_mark_sold(self):
        """Validate the delivery: the quant is written off, the deal closes.

        One button instead of a trip to Inventory -- the sales manager
        never has to leave the order.
        """
        for order in self:
            if order.state != 'sale':
                raise UserError(_("Confirm the order first."))
            pickings = order.picking_ids.filtered(
                lambda p: p.state not in ('done', 'cancel'))
            if not pickings:
                raise UserError(_(
                    "Nothing left to deliver on this order."))
            for picking in pickings:
                # Fill demanded quantities and validate in one go.
                for move in picking.move_ids:
                    move.quantity = move.product_uom_qty
                    move.picked = True
                picking.with_context(
                    skip_backorder=True).button_validate()
            order._vk_refresh_units()

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
