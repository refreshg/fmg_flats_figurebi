from odoo import _, fields, models
from odoo.exceptions import UserError


class CrmLead(models.Model):
    """Ties an opportunity to the units it is about.

    The buyer usually circles a few flats before committing, so the link is
    many2many. Reservation is deliberate and separate: attaching a unit holds
    nothing -- only the Reserve button creates and confirms the order, which
    is what actually takes the unit off the market (stock reservation).
    """

    _inherit = 'crm.lead'

    vk_unit_ids = fields.Many2many(
        'product.template',
        'crm_lead_vk_unit_rel', 'lead_id', 'product_tmpl_id',
        string="Units",
        domain=[('vk_is_unit', '=', True)],
    )
    vk_unit_count = fields.Integer(compute='_compute_vk_unit_count')
    # Comma-joined codes for the pipeline kanban card, where looping a
    # many2many is more machinery than the card is worth.
    vk_unit_codes = fields.Char(compute='_compute_vk_unit_count')

    def _compute_vk_unit_count(self):
        for lead in self:
            lead.vk_unit_count = len(lead.vk_unit_ids)
            lead.vk_unit_codes = ", ".join(
                lead.vk_unit_ids.mapped('default_code'))

    # ------------------------------------------------------------- actions

    def _vk_selector_action(self, params):
        """The visual selector, parameterised for this lead."""
        return {
            'type': 'ir.actions.client',
            'tag': 'vertikali_selector',
            'name': _("Building Selector"),
            'params': params,
        }

    def action_vk_pick_units(self):
        """Open the selector in pick mode: unit cards get an Attach button."""
        self.ensure_one()
        return self._vk_selector_action({
            'vk_pick_model': 'crm.lead',
            'vk_pick_id': self.id,
            'vk_pick_name': self.name or _("Opportunity"),
            'vk_focus_unit_ids': self.vk_unit_ids.ids,
            'vk_origin_model': 'crm.lead',
            'vk_origin_id': self.id,
            'vk_origin_name': self.name or _("Opportunity"),
        })

    def action_vk_show_units(self):
        """Open the selector on the attached units' floor, zones outlined."""
        self.ensure_one()
        if not self.vk_unit_ids:
            raise UserError(_("No units attached to this opportunity yet."))
        return self._vk_selector_action({
            'vk_focus_unit_ids': self.vk_unit_ids.ids,
            'vk_origin_model': 'crm.lead',
            'vk_origin_id': self.id,
            'vk_origin_name': self.name or _("Opportunity"),
        })

    def action_vk_reserve(self):
        """Create and confirm the order that reserves the attached units.

        Confirmation is the gate: sale_stock creates the delivery and reserves
        the single quant of each unit, and SaleOrder.action_confirm refuses
        units whose quant is already spoken for -- so a double reservation
        cannot slip through here.
        """
        self.ensure_one()
        if not self.vk_unit_ids:
            raise UserError(_("Attach at least one unit first."))
        if not self.partner_id:
            raise UserError(_(
                "Set the customer on the opportunity first -- "
                "the reservation is made out to them."))

        taken = self.vk_unit_ids.filtered(lambda u: u.vk_state != 'available')
        if taken:
            raise UserError(_(
                "Already reserved or sold: %s",
                ", ".join(taken.mapped('default_code'))))

        order = self.env['sale.order'].create({
            'partner_id': self.partner_id.id,
            'opportunity_id': self.id,
            'order_line': [
                (0, 0, {
                    'product_id': unit.product_variant_id.id,
                    'product_uom_qty': 1,
                    'price_unit': unit.list_price,
                })
                for unit in self.vk_unit_ids
            ],
        })
        order.action_confirm()

        return {
            'type': 'ir.actions.act_window',
            'res_model': 'sale.order',
            'res_id': order.id,
            'views': [(False, 'form')],
            'target': 'current',
        }
