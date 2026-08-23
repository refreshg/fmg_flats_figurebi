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

    # Shown on the project chooser, before any building is picked.
    image = fields.Image(
        string="Cover",
        help="Hero render of the development.")
    tagline = fields.Char(
        help="One line under the title, e.g. Tbilisi, Saburtalo.")
    description = fields.Text(
        help="Short description shown on the project card.")
    handover = fields.Char(
        string="Handover",
        help="Free text, e.g. Q4 2027.")

    categ_id = fields.Many2one(
        'product.category',
        string="Product Category",
        help="Category holding this project's units.",
    )
    building = fields.Char(
        help="Building label used on the units, e.g. A. "
             "Leave empty when the project has several blocks.")

    block_ids = fields.One2many(
        'vertikali.block', 'project_id', string="Blocks")

    # Lets the selector ask "is there a cover?" without downloading it.
    has_image = fields.Boolean(
        compute='_compute_has_image', store=True, string="Has Cover")

    @api.depends('image')
    def _compute_has_image(self):
        for project in self:
            project.has_image = bool(project.image)

    unit_count = fields.Integer(compute='_compute_unit_stats')
    available_count = fields.Integer(compute='_compute_unit_stats')
    price_from = fields.Monetary(
        compute='_compute_unit_stats', currency_field='currency_id')
    currency_id = fields.Many2one(
        'res.currency', compute='_compute_currency')

    def _compute_currency(self):
        for project in self:
            project.currency_id = self.env.company.currency_id

    def _compute_unit_stats(self):
        for project in self:
            units = project._units()
            available = units.filtered(lambda u: u.vk_state == 'available')
            prices = available.mapped('list_price') or units.mapped('list_price')
            project.unit_count = len(units)
            project.available_count = len(available)
            project.price_from = min(prices) if prices else 0.0

    def _units(self):
        """Units belonging to this project, by category or building label."""
        self.ensure_one()
        domain = [('vk_is_unit', '=', True)]
        if self.categ_id:
            domain.append(('categ_id', 'child_of', self.categ_id.id))
        elif self.building:
            domain.append(('vk_building', '=', self.building))
        else:
            return self.env['product.template']
        return self.env['product.template'].search(domain)

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

    def action_generate_floor_views(self):
        """Create one floor-plan view per floor that has units.

        A floor plan is a separate image per storey, so a 22-storey building
        needs 22 records. Creating them by hand is tedious and easy to get
        wrong, so they are derived from the units that already exist -- the
        images are then uploaded onto the records.
        """
        self.ensure_one()
        if not self.use_floorplan:
            raise ValidationError(_(
                "Switch on the Floor Plan step before generating floor views."))

        domain = [('vk_is_unit', '=', True)]
        if self.building:
            domain.append(('vk_building', '=', self.building))
        elif self.categ_id:
            domain.append(('categ_id', 'child_of', self.categ_id.id))
        units = self.env['product.template'].search(domain)
        # One plan per floor *per section*: a storey split across entrances is
        # several drawings, not one. Units with no section give a single plan
        # covering the whole floor.
        combos = sorted(
            {(u.vk_floor, u.vk_section or False) for u in units if u.vk_floor},
            key=lambda c: (-c[0], c[1] or ''),
        )
        if not combos:
            raise ValidationError(_(
                "No units found for this project, so there are no floors to "
                "generate. Add the units first."))

        existing = self.env['vertikali.view'].search([
            ('project_id', '=', self.id), ('view_type', '=', 'floor')])
        have = {(v.floor, v.section or False) for v in existing}

        vals = []
        for floor, section in combos:
            if (floor, section) in have:
                continue
            label = _("%(building)s - Floor %(floor)s",
                      building=self.building or self.name, floor=floor)
            if section:
                label = _("%(label)s · Section %(section)s",
                          label=label, section=section)
            vals.append({
                'name': label,
                'project_id': self.id,
                'view_type': 'floor',
                'building': self.building,
                'floor': floor,
                'section': section or False,
                'categ_id': self.categ_id.id,
                'sequence': 100 - floor,
            })

        created = self.env['vertikali.view'].create(vals) if vals else \
            self.env['vertikali.view']

        # Point the facade's floor zones at the matching floor views, so the
        # facade actually drills through instead of dead-ending.
        linked = self._link_facade_zones()

        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': _("Floor views ready"),
                'message': _(
                    "%(created)s created, %(skipped)s already existed, "
                    "%(linked)s facade zones linked. Upload each plan "
                    "on its view.",
                    created=len(created), skipped=len(combos) - len(vals),
                    linked=linked,
                ),
                'type': 'success',
                'next': {'type': 'ir.actions.act_window_close'},
            },
        }

    def _link_facade_zones(self):
        """Wire facade zones to their floor plan.

        Matches on floor *and* section, so a band over section 2 opens that
        wing's plan rather than whichever plan happens to share the storey.
        A sectioned band falls back to the floor-wide plan when its own
        section has none.
        """
        self.ensure_one()
        floor_views = self.env['vertikali.view'].search([
            ('project_id', '=', self.id), ('view_type', '=', 'floor')])
        by_key = {(v.floor, v.section or False): v for v in floor_views}
        if not by_key:
            return 0

        zones = self.env['vertikali.polygon'].search([
            ('view_id.project_id', '=', self.id),
            ('view_id.view_type', '=', 'facade'),
            ('floor', '!=', False),
        ])
        count = 0
        for zone in zones:
            target = (by_key.get((zone.floor, zone.section or False))
                      or by_key.get((zone.floor, False)))
            if target and zone.target_view_id != target:
                zone.target_view_id = target
                count += 1
        return count


class VertikaliBlock(models.Model):
    """One tower within a project.

    A development is usually several blocks (A, B, ...) sharing a masterplan.
    The masterplan highlights each block in turn; picking one enters its
    facade. Units are matched by vk_building.
    """

    _name = 'vertikali.block'
    _description = "Block"
    _order = 'sequence, code, id'

    name = fields.Char(required=True)
    code = fields.Char(
        required=True,
        help="Label shown on the switcher, e.g. A.")
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)

    project_id = fields.Many2one(
        'vertikali.project', required=True, ondelete='cascade', index=True)

    # Highlight on the project's masterplan, normalized 0..1 like every other
    # polygon in this module.
    points = fields.Text(
        string="Masterplan Shape",
        help="Normalized polygon over the project cover, as JSON.")

    color = fields.Char(
        default="#1aa179",
        help="Swatch colour on the block switcher.")

    facade_view_id = fields.Many2one(
        'vertikali.view', string="Facade",
        domain="[('view_type', '=', 'facade')]")

    floors = fields.Integer(help="Storeys in this block.")

    unit_count = fields.Integer(compute='_compute_unit_stats')
    available_count = fields.Integer(compute='_compute_unit_stats')

    def _compute_unit_stats(self):
        for block in self:
            units = self.env['product.template'].search([
                ('vk_is_unit', '=', True),
                ('vk_building', '=', block.code),
            ])
            block.unit_count = len(units)
            block.available_count = len(
                units.filtered(lambda u: u.vk_state == 'available'))

    @api.constrains('points')
    def _check_points(self):
        for block in self:
            if not block.points:
                continue
            _validate_normalized_points(block.points)


def _validate_normalized_points(raw):
    """Shared by blocks and polygons: points must be a 0..1 JSON ring."""
    try:
        pts = json.loads(raw or '')
    except ValueError:
        raise ValidationError(_("Points must be valid JSON."))
    if not isinstance(pts, list) or len(pts) < 3:
        raise ValidationError(_("A shape needs at least 3 points."))
    for pt in pts:
        if (not isinstance(pt, (list, tuple)) or len(pt) != 2
                or not all(isinstance(c, (int, float)) for c in pt)):
            raise ValidationError(
                _("Each point must be a [x, y] pair of numbers."))
        if not all(0 <= c <= 1 for c in pt):
            raise ValidationError(_(
                "Points must be normalized between 0 and 1 so the shape "
                "scales with the image. Got: [%(x)s, %(y)s]",
                x=pt[0], y=pt[1]))


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

    # A storey split across entrances needs one plan per section, not one per
    # floor: each wing is a separate drawing. Empty means the plan covers the
    # whole floor, which is the single-section case.
    section = fields.Char(
        help="Section this plan covers, e.g. 1. Empty means the whole floor.")

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

    # Generated floor views start empty, so the list needs to show at a glance
    # which ones are still waiting for their plan.
    has_image = fields.Boolean(
        compute='_compute_has_image', string="Image", store=True)

    @api.depends('image')
    def _compute_has_image(self):
        for view in self:
            view.has_image = bool(view.image)

    def action_open_copy_wizard(self):
        """Ask which storeys to copy onto, rather than assuming all of them.

        A tower usually repeats one typical floor, but rarely every floor: the
        ground level, a penthouse or a service storey differ. So the targets
        are ticked from the project's real floor views.
        """
        self.ensure_one()
        if self.view_type != 'floor':
            raise ValidationError(_(
                "Only floor plans can be copied across floors."))
        if not self.image:
            raise ValidationError(_(
                "Upload the plan on this view first, then copy it."))
        wizard = self.env['vertikali.copy.plan.wizard'].create({
            'source_view_id': self.id,
        })
        return {
            'type': 'ir.actions.act_window',
            'name': _("Copy plan to floors"),
            'res_model': 'vertikali.copy.plan.wizard',
            'res_id': wizard.id,
            'view_mode': 'form',
            'target': 'new',
        }

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

    # A masterplan zone can stand for a whole block instead of a view, so the
    # number of towers is whatever has been drawn -- no fixed A/B list.
    block_id = fields.Many2one(
        'vertikali.block', string="Block", ondelete='cascade', index=True)

    # A facade band covers a whole storey, so it stands for several units at
    # once -- product_tmpl_id holds a single unit and only suits a floor-plan
    # zone. Listing them here lets the band report what it sells.
    product_tmpl_ids = fields.Many2many(
        'product.template',
        'vertikali_polygon_product_rel', 'polygon_id', 'product_tmpl_id',
        string="Units",
        domain="[('vk_is_unit', '=', True)]",
    )

    unit_count = fields.Integer(
        compute='_compute_unit_stats', string="Units")
    available_count = fields.Integer(
        compute='_compute_unit_stats', string="Available")
    reserved_count = fields.Integer(
        compute='_compute_unit_stats', string="Reserved")
    sold_count = fields.Integer(
        compute='_compute_unit_stats', string="Sold")
    price_from = fields.Monetary(
        compute='_compute_unit_stats', currency_field='currency_id',
        string="From")
    currency_id = fields.Many2one(
        'res.currency', compute='_compute_currency')

    def _compute_currency(self):
        for poly in self:
            poly.currency_id = self.env.company.currency_id

    @api.depends('product_tmpl_ids.vk_state', 'product_tmpl_ids.list_price')
    def _compute_unit_stats(self):
        for poly in self:
            units = poly.product_tmpl_ids
            by = lambda s: units.filtered(lambda u: u.vk_state == s)
            available = by('available')
            poly.unit_count = len(units)
            poly.available_count = len(available)
            poly.reserved_count = len(by('reserved'))
            poly.sold_count = len(by('sold'))
            # Quote from what can still be bought; fall back to the whole band
            # so a fully sold floor still shows a figure.
            prices = available.mapped('list_price') or units.mapped('list_price')
            poly.price_from = min(prices) if prices else 0.0

    # A storey is often split into several bands across the facade -- one per
    # entrance or wing -- so a zone covers one section of one floor, not the
    # whole floor. Left empty the zone means the entire storey.
    section = fields.Char(
        help="Section this band covers, e.g. 1. Leave empty for the whole floor.")

    def _unit_domain(self):
        """Units this zone stands for: floor, plus section and building."""
        self.ensure_one()
        domain = [('vk_is_unit', '=', True), ('vk_floor', '=', self.floor)]
        if self.section:
            domain.append(('vk_section', '=', self.section))
        building = self.view_id.building
        if building:
            domain.append(('vk_building', '=', building))
        return domain

    def action_fill_units_from_floor(self):
        """Attach the units this zone covers.

        A band drawn over storey 5 usually means "floor 5" -- or, on a facade
        split into wings, "floor 5, section 2". Filling from the floor beats
        ticking boxes by hand; the building comes from the view, so blocks do
        not bleed into each other.
        """
        for poly in self:
            if not poly.floor:
                raise ValidationError(_(
                    "Set the zone's floor first — without it there is no way "
                    "to tell which units it covers."))
            poly.product_tmpl_ids = [
                (6, 0, self.env['product.template'].search(poly._unit_domain()).ids)]
    product_tmpl_id = fields.Many2one(
        'product.template', string="Unit", ondelete='cascade', index=True,
        domain="[('vk_is_unit', '=', True)]")

    # Denormalized for floor zones on a facade, where no single unit applies.
    floor = fields.Integer(help="Floor this zone represents, on a facade view.")

    @api.model_create_multi
    def create(self, vals_list):
        """Inherit the view's floor and section when they are not given.

        A zone drawn on a floor plan belongs to that storey; leaving floor at 0
        made tooltips read "Floor 0" and broke every lookup keyed on it.
        """
        views = self.env['vertikali.view'].browse([
            v['view_id'] for v in vals_list if v.get('view_id')])
        by_id = {v.id: v for v in views}
        for vals in vals_list:
            view = by_id.get(vals.get('view_id'))
            if not view or view.view_type != 'floor':
                continue
            if not vals.get('floor') and view.floor:
                vals['floor'] = view.floor
            if not vals.get('section') and view.section:
                vals['section'] = view.section
        return super().create(vals_list)

    @api.constrains('points')
    def _check_points(self):
        for poly in self:
            _validate_normalized_points(poly.points)

    @api.constrains('target_view_id', 'product_tmpl_id')
    def _check_target(self):
        for poly in self:
            if poly.target_view_id and poly.product_tmpl_id:
                raise ValidationError(_(
                    "A zone opens either another view or a unit, not both."))
