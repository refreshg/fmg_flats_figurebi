from odoo import _, api, fields, models


class VertikaliLayout(models.Model):
    """A flat type shared by every unit built to the same drawing.

    A tower repeats a handful of layouts across its storeys, so the plan and
    its renders are held once here instead of being uploaded onto each of the
    126 units. A unit's own image still wins when one is set -- this is the
    fallback, not an override.
    """

    _name = 'vertikali.layout'
    _description = "Layout Type"
    _order = 'sequence, name'

    name = fields.Char(required=True, help="e.g. 2+1 corner, 68.8 m².")
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)

    code = fields.Char(help="Short label, e.g. A1.")
    rooms = fields.Selection(
        selection=[
            ('studio', "Studio"),
            ('1+1', "1+1"),
            ('2+1', "2+1"),
            ('3+1', "3+1"),
            ('4+1', "4+1"),
            ('commercial', "Commercial"),
        ],
        string="Layout",
    )
    area_total = fields.Float(string="Total Area (m²)", digits=(8, 2))

    image = fields.Image(string="Plan")
    # Lets the selector ask "is there a plan?" without pulling the plan itself
    # down the RPC just to find out.
    has_image = fields.Boolean(
        compute='_compute_has_image', store=True, string="Has Plan")
    image_ids = fields.One2many(
        'vertikali.unit.image', 'layout_id', string="Extra Images")

    @api.depends('image')
    def _compute_has_image(self):
        for layout in self:
            layout.has_image = bool(layout.image)

    product_tmpl_ids = fields.One2many(
        'product.template', 'vk_layout_id', string="Units")
    unit_count = fields.Integer(compute='_compute_unit_count')

    @api.depends('product_tmpl_ids')
    def _compute_unit_count(self):
        for layout in self:
            layout.unit_count = len(layout.product_tmpl_ids)

    def action_view_units(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': _("Units — %s", self.name),
            'res_model': 'product.template',
            'view_mode': 'list,form',
            'domain': [('vk_layout_id', '=', self.id)],
        }


class VertikaliUnitImage(models.Model):
    """One extra picture, on a unit or on a shared layout.

    website_sale's product.image is not installed here, so galleries get their
    own model; hanging it off either parent keeps one gallery implementation
    rather than two.
    """

    _name = 'vertikali.unit.image'
    _description = "Unit Image"
    _order = 'sequence, id'

    name = fields.Char(required=True, default="Image")
    sequence = fields.Integer(default=10)
    image = fields.Image(required=True)

    product_tmpl_id = fields.Many2one(
        'product.template', string="Unit", ondelete='cascade', index=True)
    layout_id = fields.Many2one(
        'vertikali.layout', string="Layout", ondelete='cascade', index=True)
