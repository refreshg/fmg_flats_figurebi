import json

from odoo import _, api, fields, models
from odoo.exceptions import ValidationError


class VertikaliProject(models.Model):
    """A building or complex, and which navigation steps it actually uses.

    Projects differ: some have no facade render, some no floor plans, some sell
    from a grid alone. Rather than assume one route, each step is switched on
    per project, and the navigation follows whatever remains:

        facade -> floor plan -> unit
        grid   -> unit
    """

    _name = 'vertikali.project'
    _description = "Estate Project"
    _inherit = ['mail.thread']
    _order = 'sequence, id'

    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)

    categ_id = fields.Many2one(
        'product.category',
        string="Product Category",
        help="Category holding this project's units.",
    )
    building = fields.Char(
        help="Building label used on the units, e.g. A.")

    # Navigation steps. A project needs at least one entry point; the
    # constraint below enforces that.
    use_masterplan = fields.Boolean(
        string="Masterplan", default=False,
        help="Start from a site plan showing several buildings.")
    use_facade = fields.Boolean(
        string="Facade", default=True,
        help="Pick a floor by clicking the building render.")
    use_floorplan = fields.Boolean(
        string="Floor Plan", default=True,
        help="Pick a unit from the floor's top-down plan.")
    use_grid = fields.Boolean(
        string="Grid (shakhmatka)", default=True,
        help="Pick a unit from the floor-by-floor table.")

    view_ids = fields.One2many('vertikali.view', 'project_id', string="Views")

    @api.constrains('use_masterplan', 'use_facade', 'use_floorplan', 'use_grid')
    def _check_has_entry_point(self):
        for project in self:
            if not any((project.use_masterplan, project.use_facade,
                        project.use_floorplan, project.use_grid)):
                raise ValidationError(_(
                    "%(name)s needs at least one navigation step: a masterplan, "
                    "a facade, floor plans or the grid.",
                    name=project.name,
                ))

    def _vk_steps(self):
        """Ordered navigation steps for this project."""
        self.ensure_one()
        steps = []
        if self.use_masterplan:
            steps.append('masterplan')
        if self.use_facade:
            steps.append('facade')
        if self.use_floorplan:
            steps.append('floor')
        if self.use_grid:
            steps.append('grid')
        return steps


class VertikaliView(models.Model):
    """A clickable image: masterplan, building facade or floor plan.

    Odoo can store an image and it can render SVG, but it has no widget for
    "image with clickable regions bound to records" -- hence this model plus
    the polygons that hang off it.
    """

    _name = 'vertikali.view'
    _description = "Visual View (masterplan / facade / floor plan)"
    _inherit = ['mail.thread']
    _order = 'view_type, sequence, id'

    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)

    view_type = fields.Selection(
        selection=[
            ('masterplan', "Masterplan"),
            ('facade', "Building Facade"),
            ('floor', "Floor Plan"),
        ],
        string="Type",
        required=True,
        default='facade',
    )

    image = fields.Image(
        string="Background",
        help="Render or drawing the polygons are drawn on top of.",
    )

    # Which slice of the project this view shows. Buildings and floors are
    # plain labels here, matching the vk_* fields on the product.
    building = fields.Char(help="Building label, e.g. A.")
    floor = fields.Integer(help="Floor number, for floor plans.")

    project_id = fields.Many2one(
        'vertikali.project', string="Project", index=True, ondelete='cascade')

    categ_id = fields.Many2one(
        'product.category',
        string="Category",
        help="Product category holding this project's units.",
    )

    polygon_ids = fields.One2many(
        'vertikali.polygon', 'view_id', string="Zones")
    polygon_count = fields.Integer(
        compute='_compute_polygon_count', string="Zones")

    @api.depends('polygon_ids')
    def _compute_polygon_count(self):
        for view in self:
            view.polygon_count = len(view.polygon_ids)


class VertikaliPolygon(models.Model):
    """One clickable region on a view.

    Points are stored normalized (0..1) rather than in pixels so the same
    polygon lines up whatever size the image is rendered at -- the editor and
    the selector both work off the fractions.
    """

    _name = 'vertikali.polygon'
    _description = "Clickable Zone"
    _order = 'view_id, sequence, id'

    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)

    view_id = fields.Many2one(
        'vertikali.view', required=True, ondelete='cascade', index=True)

    # JSON: [[x, y], ...] with each value between 0 and 1.
    points = fields.Text(
        required=True,
        help="Normalized polygon points as JSON, e.g. [[0.1,0.2],[0.4,0.2]].",
    )

    # A zone leads either to another view (masterplan -> facade -> floor) or to
    # a single unit. Exactly one target, enforced below.
    target_view_id = fields.Many2one(
        'vertikali.view', string="Opens View", ondelete='set null')
    product_tmpl_id = fields.Many2one(
        'product.template', string="Unit", ondelete='cascade', index=True,
        domain="[('vk_is_unit', '=', True)]")

    # Denormalized for floor zones on a facade, where no single unit applies.
    floor = fields.Integer(help="Floor this zone represents, on a facade view.")

    @api.constrains('points')
    def _check_points(self):
        for poly in self:
            try:
                pts = json.loads(poly.points or '')
            except ValueError:
                raise ValidationError(_("Points must be valid JSON."))
            if not isinstance(pts, list) or len(pts) < 3:
                raise ValidationError(
                    _("A zone needs at least 3 points."))
            for pt in pts:
                if (not isinstance(pt, (list, tuple)) or len(pt) != 2
                        or not all(isinstance(c, (int, float)) for c in pt)):
                    raise ValidationError(
                        _("Each point must be a [x, y] pair of numbers."))
                if not all(0 <= c <= 1 for c in pt):
                    raise ValidationError(_(
                        "Points must be normalized between 0 and 1 so the "
                        "zone scales with the image. Got: [%(x)s, %(y)s]",
                        x=pt[0], y=pt[1]))

    @api.constrains('target_view_id', 'product_tmpl_id')
    def _check_target(self):
        for poly in self:
            if poly.target_view_id and poly.product_tmpl_id:
                raise ValidationError(_(
                    "A zone opens either another view or a unit, not both."))
