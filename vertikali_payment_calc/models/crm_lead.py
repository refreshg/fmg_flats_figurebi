from odoo import _, api, fields, models
from odoo.exceptions import UserError

# The units a deal is about, where the host records them. vertikali keeps a
# many2many; a database without it simply opens the calculator with the flat
# left to be chosen.
LEAD_UNITS_FIELD = 'vk_unit_ids'


class CrmLead(models.Model):
    _inherit = 'crm.lead'

    vk_calc_ids = fields.One2many(
        'vertikali.payment.calc', 'lead_id', string="კალკულაციები")
    vk_calc_count = fields.Integer(compute='_compute_vk_calc_count')
    vk_schedule_id = fields.Many2one(
        'vertikali.payment.calc', string="რეალური გრაფიკი",
        compute='_compute_vk_calc_count')

    @api.depends('vk_calc_ids.is_schedule')
    def _compute_vk_calc_count(self):
        for lead in self:
            lead.vk_calc_count = len(lead.vk_calc_ids)
            lead.vk_schedule_id = lead.vk_calc_ids.filtered('is_schedule')[:1]

    def _vk_lead_units(self):
        self.ensure_one()
        units = getattr(self, LEAD_UNITS_FIELD, None)
        return units if units is not None else self.env['product.template']

    def action_vk_calculator(self):
        """Open a new calculation for this deal, as a dialog.

        With one flat attached it is filled in and locked; with several, the
        flat is chosen in the dialog from those on the deal. Prices arrive
        through the unit onchange, so the rate lives in one place.
        """
        self.ensure_one()
        units = self._vk_lead_units()
        ctx = dict(self.env.context, default_lead_id=self.id)
        if len(units) == 1:
            ctx.update(default_unit_id=units.id, vk_unit_locked=True)
        elif units:
            ctx['vk_unit_ids'] = units.ids
        return {
            'type': 'ir.actions.act_window',
            'name': _("განვადების კალკულატორი"),
            'res_model': 'vertikali.payment.calc',
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'new',
            'context': ctx,
        }

    def action_vk_open_calcs(self):
        """The calculations already made on this deal, schedule first."""
        self.ensure_one()
        if not self.vk_calc_ids:
            raise UserError(_("ამ ლიდზე კალკულაცია ჯერ არ არის."))
        return {
            'type': 'ir.actions.act_window',
            'name': _("განვადების კალკულაციები"),
            'res_model': 'vertikali.payment.calc',
            'view_mode': 'list,form',
            'domain': [('lead_id', '=', self.id)],
            'context': {'default_lead_id': self.id},
        }
