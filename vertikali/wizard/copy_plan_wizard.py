from odoo import _, api, fields, models
from odoo.exceptions import ValidationError


class VertikaliCopyPlanWizard(models.TransientModel):
    """Pick which storeys a floor plan and its zones are copied onto.

    Copying to *every* floor is the common case but not the only one -- a
    tower often has a different ground floor, penthouse or service level. So
    the target floors are shown as real records to tick rather than guessed.
    """

    _name = 'vertikali.copy.plan.wizard'
    _description = "Copy Plan to Floors"

    source_view_id = fields.Many2one(
        'vertikali.view', required=True, ondelete='cascade')
    target_view_ids = fields.Many2many(
        'vertikali.view', string="Copy to Floors",
        domain="[('id', 'in', available_view_ids)]")
    available_view_ids = fields.Many2many(
        'vertikali.view', 'vertikali_copy_wizard_avail_rel',
        compute='_compute_available_view_ids')

    copy_zones = fields.Boolean(
        string="Also copy the zones", default=True,
        help="Copy the outlines too. Their unit links are not copied: the "
             "outline repeats from floor to floor, the flats behind it do not.")

    @api.depends('source_view_id')
    def _compute_available_view_ids(self):
        for wiz in self:
            src = wiz.source_view_id
            if not src:
                wiz.available_view_ids = False
                continue
            domain = [
                ('view_type', '=', 'floor'),
                ('id', '!=', src.id),
            ]
            if src.project_id:
                domain.append(('project_id', '=', src.project_id.id))
            if src.building:
                domain.append(('building', '=', src.building))
            wiz.available_view_ids = self.env['vertikali.view'].search(domain)

    def action_apply(self):
        self.ensure_one()
        src = self.source_view_id
        if not src.image:
            raise ValidationError(_(
                "Upload the plan on the source view first."))
        targets = self.target_view_ids
        if not targets:
            raise ValidationError(_("Pick at least one floor to copy onto."))

        vals = {'image': src.image}
        # A sectioned source implies its targets belong to that section too,
        # otherwise the facade could never route to them.
        if src.section:
            vals['section'] = src.section
        targets.write(vals)

        copied = 0
        if self.copy_zones and src.polygon_ids:
            targets.mapped('polygon_ids').unlink()
            rows = []
            for target in targets:
                for zone in src.polygon_ids:
                    rows.append({
                        'name': zone.name,
                        'sequence': zone.sequence,
                        'view_id': target.id,
                        'points': zone.points,
                        'floor': target.floor,
                        'section': target.section or src.section or False,
                    })
            self.env['vertikali.polygon'].create(rows)
            copied = len(rows)

        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': _("Plan copied"),
                'message': _(
                    "%(floors)s floor(s) updated, %(zones)s zone(s) drawn. "
                    "Assign the units per floor.",
                    floors=len(targets), zones=copied,
                ),
                'type': 'success',
                'next': {'type': 'ir.actions.act_window_close'},
            },
        }

    def action_select_all(self):
        self.ensure_one()
        self.target_view_ids = [(6, 0, self.available_view_ids.ids)]
        return {
            'type': 'ir.actions.act_window',
            'res_model': self._name,
            'res_id': self.id,
            'view_mode': 'form',
            'target': 'new',
        }
