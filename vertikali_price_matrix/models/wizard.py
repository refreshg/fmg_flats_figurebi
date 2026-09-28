# -*- coding: utf-8 -*-
"""მატრიცის ფორმირება — the popup that builds the table from the units.

Pick the units (project, block, view, layout, types, status), say how many
stage COLUMNS the table has, and "დაგენერირება" forms one line per type
found among them. Nothing else: quantities and prices per stage are typed
in the table itself, type by type, and a column is added there too, from
the "ეტაპის დამატება" switch above it (D-44, D-45).

Transient model: nothing of the popup is kept beyond the click."""
from odoo import api, fields, models
from odoo.exceptions import UserError

from .price_matrix import MAX_STAGES


class VertikaliPriceMatrixWizard(models.TransientModel):
    _name = 'vertikali.price.matrix.wizard'
    _description = 'მატრიცის ფორმირება'

    matrix_id = fields.Many2one('vertikali.price.matrix', string='მატრიცა', required=True,
                                ondelete='cascade')
    currency_id = fields.Many2one(related='matrix_id.currency_id')
    project_id = fields.Many2one('vertikali.project', string='პროექტი',
                                 help="ბინები ამ პროექტიდან იკითხება. ცარიელი = ხაზები მხოლოდ არჩეული ტიპებიდან, რაოდენობები ხელით.")
    f_building = fields.Char(string='კორპუსი / ბლოკი', help="A ან A, B. ცარიელი = ყველა.")
    f_view_ids = fields.Many2many('vertikali.option', 'vk_pm_wizard_view_rel', string='ხედი',
                                  domain=[('attribute', '=', 'view')],
                                  help="ცარიელი = ყველა ხედი.")
    f_layout_ids = fields.Many2many('vertikali.price.matrix.layout', 'vk_pm_wizard_layout_rel', string='ოთახიანობა',
                                    help="ცარიელი = ყველა ოთახიანობა.")
    f_type_ids = fields.Many2many('vertikali.price.matrix.type', string='ტიპები',
                                  help="ცარიელი = ყველა ტიპი, რომელიც ბინებში მოიძებნება.")
    # the types the chosen units actually have: the type list offers these
    available_type_ids = fields.Many2many('vertikali.price.matrix.type', 'vk_pm_wizard_available_rel',
                                          compute='_compute_available_type_ids')
    f_state_ids = fields.Many2many('vertikali.price.matrix.state', string='სტატუსი',
                                   help="ცარიელი = ყველა სტატუსი.")
    unit_count = fields.Integer(string='ბინა ფილტრში', compute='_compute_unit_count')
    # the one figure the popup asks for: how many stage column pairs the
    # table carries. The quantities and the prices are typed in the table.
    stage_count = fields.Integer(string='სვეტების რაოდენობა (ეტაპები)', required=True, default=3,
                                 help="რამდენი ეტაპის სვეტი გამოჩნდეს ცხრილში. თითო ეტაპს ორი სვეტი აქვს - "
                                      "რაოდენობა და ფასი მ² - და ცხრილში ხელით ივსება.")

    user_id = fields.Many2one('res.users', string='პასუხისმგებელი', required=True,
                              default=lambda self: self.env.user,
                              help="ვინ იღებს ამ გადაწყვეტილებას.")
    reason = fields.Char(string='მიზეზი', required=True,
                         help="რატომ იცვლება მატრიცა - ისტორიაში ჩაიწერება.")

    @api.model
    def default_get(self, fields_list):
        vals = super().default_get(fields_list)
        ctx = self.env.context
        # opened from the ⚙ Actions menu of a matrix: the record is active_id
        mid = vals.get('matrix_id') or ctx.get('default_matrix_id')
        if not mid and ctx.get('active_model') == 'vertikali.price.matrix':
            mid = ctx.get('active_id')
        m = self.env['vertikali.price.matrix'].browse(mid)
        if m:
            vals['matrix_id'] = m.id
            vals.update(project_id=m.project_id.id, f_building=m.f_building,
                        f_view_ids=[(6, 0, m.f_view_ids.ids)], f_layout_ids=[(6, 0, m.f_layout_ids.ids)],
                        f_type_ids=[(6, 0, m.f_type_ids.ids)],
                        f_state_ids=[(6, 0, m.f_state_ids.ids)],
                        stage_count=max(1, min(m.stage_count or 3, MAX_STAGES)))
        return vals

    def _matrix_vals(self):
        self.ensure_one()
        return {
            'project_id': self.project_id.id, 'f_building': self.f_building,
            'f_view_ids': [(6, 0, self.f_view_ids.ids)],
            'f_layout_ids': [(6, 0, self.f_layout_ids.ids)],
            'f_type_ids': [(6, 0, self.f_type_ids.ids)],
            'f_state_ids': [(6, 0, self.f_state_ids.ids)],
        }

    @api.depends('project_id', 'f_building', 'f_view_ids', 'f_layout_ids', 'f_state_ids')
    def _compute_available_type_ids(self):
        Type = self.env['vertikali.price.matrix.type']
        for wiz in self:
            if not wiz.project_id or not wiz.matrix_id:
                wiz.available_type_ids = Type.search([])
                continue
            probe = wiz.matrix_id.new(dict(wiz._matrix_vals(), f_type_ids=[], name='probe'))
            codes = {probe._type_code(u) for u in probe._units()}
            wiz.available_type_ids = Type.search([('code', 'in', list(codes))])

    @api.depends('project_id', 'f_building', 'f_view_ids', 'f_layout_ids', 'f_type_ids', 'f_state_ids')
    def _compute_unit_count(self):
        for wiz in self:
            if not wiz.project_id or not wiz.matrix_id:
                wiz.unit_count = 0
                continue
            probe = wiz.matrix_id.new(dict(wiz._matrix_vals(), name='probe'))
            wiz.unit_count = len(probe._units())

    def action_generate(self):
        """Write the filter and the number of stage columns, then form the
        lines from the units. A line that exists keeps its quantities and
        prices; a new one starts on stage I with the units' average price
        per m², and the rest of the stages are typed in the table."""
        self.ensure_one()
        if not 1 <= self.stage_count <= MAX_STAGES:
            raise UserError("სვეტების რაოდენობა 1-დან %d-მდე შეიძლება იყოს." % MAX_STAGES)
        m = self.matrix_id.with_context(vk_trim=True, vk_reason=self.reason).with_user(self.user_id)
        m.write(dict(self._matrix_vals(), stage_count=self.stage_count,
                     last_user_id=self.user_id.id, last_reason=self.reason))
        m.action_generate()
        m._log('ახალი გენერაცია', '', '%s | %d ეტაპის სვეტი' % (m.filter_summary, self.stage_count),
               reason=self.reason, user=self.user_id)
        return {'type': 'ir.actions.act_window_close'}
