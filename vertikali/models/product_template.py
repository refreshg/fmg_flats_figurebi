from odoo import _, api, fields, models
from odoo.exceptions import ValidationError


class ProductTemplate(models.Model):
    """Apartment-specific data on the standard product.

    Design note (standard-first): everything the stock product already provides
    is reused as-is -- ``default_code`` is the unit code (A-0504), ``list_price``
    the price, ``categ_id`` the project/building hierarchy, ``image_1920`` the
    floor plan, ``product_tag_ids`` the feature tags.

    Only apartment attributes that must be sortable, groupable or computed live
    here as real fields. ``product_properties`` stays available for secondary
    attributes (finish type, view description) that never need sorting -- those
    should NOT be duplicated here.
    """

    _inherit = 'product.template'

    # Marks a product as a sellable apartment. Keeps unit views and reporting
    # from picking up ordinary products (services, fees, materials).
    vk_is_unit = fields.Boolean(
        string="Is a Unit",
        default=False,
        index=True,
        help="Tick for apartments and commercial units sold from a project.",
    )

    vk_building = fields.Char(
        string="Building",
        index=True,
        help="Building label as shown to buyers, e.g. A, B, C.",
    )
    # A tower is usually split into entrances/risers. The grid groups columns
    # by section, which is what makes a wide building readable.
    vk_section = fields.Char(
        string="Section",
        index=True,
        help="Entrance or riser within the building, e.g. 1, 2, 3.",
    )
    vk_floor = fields.Integer(
        string="Floor",
        index=True,
    )
    vk_rooms = fields.Selection(
        selection=[
            ('studio', "Studio"),
            ('1+1', "1+1"),
            ('2+1', "2+1"),
            ('3+1', "3+1"),
            ('4+1', "4+1"),
            ('commercial', "Commercial"),
        ],
        string="Layout",
        index=True,
    )
    vk_orientation = fields.Selection(
        selection=[
            ('n', "North"), ('ne', "North-East"), ('e', "East"), ('se', "South-East"),
            ('s', "South"), ('sw', "South-West"), ('w', "West"), ('nw', "North-West"),
        ],
        string="Orientation",
    )

    # Areas are stored in square metres. Kept as plain floats rather than
    # uom-based fields: the sales UoM stays "Units" (one apartment), so area is
    # descriptive data, not a quantity to convert.
    vk_area_total = fields.Float(
        string="Total Area (m²)",
        digits=(8, 2),
    )
    vk_area_living = fields.Float(
        string="Living Area (m²)",
        digits=(8, 2),
    )
    vk_area_balcony = fields.Float(
        string="Balcony Area (m²)",
        digits=(8, 2),
    )

    # Stored so the list view can sort and group on it -- the main reason these
    # are real fields instead of product_properties, which cannot be computed.
    vk_price_sqm = fields.Monetary(
        string="Price / m²",
        compute='_compute_vk_price_sqm',
        store=True,
        currency_field='currency_id',
        help="Sales price divided by total area.",
    )

    vk_handover = fields.Date(
        string="Handover",
        help="Planned handover date for this unit.",
    )

    # Room-by-room areas for the unit card. Free text rather than a child
    # model: it is display-only, never aggregated or searched, and typing
    # "Bedroom 12.4" beats maintaining a table of one-line records.
    vk_rooms_detail = fields.Text(
        string="Room Areas",
        help="One room per line, e.g. 'Living 20.0'. Shown on the unit card.",
    )

    vk_condition = fields.Selection(
        selection=[
            ('frame', "Frame"),
            ('white', "White frame"),
            ('green', "Green frame"),
            ('renovated', "Renovated"),
        ],
        string="Condition",
    )

    # Extra views of the unit -- furnished render, 3D, view from the window.
    # Our own model rather than product.image, which ships with website_sale
    # and is not installed here.
    vk_image_ids = fields.One2many(
        'vertikali.unit.image', 'product_tmpl_id', string="Extra Images")

    # product.template carries no such flag of its own, and the selector needs
    # to know whether a unit has a drawing before deciding to fall back to the
    # shared layout -- without pulling image_1920 itself down the RPC to check.
    vk_has_image = fields.Boolean(
        compute='_compute_vk_has_image', store=True, string="Has Plan")

    # A typical flat repeats across the tower, so its drawing is shared rather
    # than uploaded 126 times. The unit's own image still wins when set.
    vk_layout_id = fields.Many2one(
        'vertikali.layout', string="Layout Type",
        help="Shared drawing for this flat type. Used when the unit has no "
             "image of its own.")

    @api.depends('image_1920')
    def _compute_vk_has_image(self):
        for tmpl in self:
            tmpl.vk_has_image = bool(tmpl.image_1920)

    def vk_room_lines(self):
        """Parse vk_rooms_detail into [(label, area)] for display."""
        self.ensure_one()
        out = []
        for line in (self.vk_rooms_detail or '').splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.rsplit(None, 1)
            if len(parts) == 2:
                try:
                    out.append((parts[0], float(parts[1])))
                    continue
                except ValueError:
                    pass
            out.append((line, None))
        return out

    # Derived from the sales pipeline rather than typed by hand, so the grid
    # can never disagree with the orders. Stored because the shakhmatka sorts,
    # groups and filters on it -- the standard qty_available and sales_count
    # are non-stored computes and cannot serve that.
    vk_state = fields.Selection(
        selection=[
            ('available', "Available"),
            ('reserved', "Reserved"),
            ('sold', "Sold"),
        ],
        string="Unit Status",
        compute='_compute_vk_state',
        store=True,
        index=True,
        default='available',
    )

    def _compute_vk_state(self):
        """Derive availability from the quotations and orders on the unit.

        Recomputed from an explicit search rather than a dependency chain:
        product.product has no sale-line one2many to depend on, and
        sale.order.line.product_template_id is a non-stored related field.
        The sale.order.line override below re-triggers this on every change.
        """
        units = self.filtered('vk_is_unit')
        (self - units).vk_state = 'available'
        if not units:
            return

        lines = self.env['sale.order.line'].sudo().search([
            ('product_id.product_tmpl_id', 'in', units.ids),
            ('state', 'in', ['draft', 'sent', 'sale']),
        ])
        states = {}
        for line in lines:
            tmpl_id = line.product_id.product_tmpl_id.id
            states.setdefault(tmpl_id, set()).add(line.state)

        for tmpl in units:
            found = states.get(tmpl.id, set())
            if 'sale' in found:
                # A confirmed order takes the unit off the market.
                tmpl.vk_state = 'sold'
            elif found:
                # Quoted but not confirmed: held, still winnable.
                tmpl.vk_state = 'reserved'
            else:
                tmpl.vk_state = 'available'

    @api.depends('list_price', 'vk_area_total')
    def _compute_vk_price_sqm(self):
        for tmpl in self:
            # Guard against division by zero for products with no area set.
            tmpl.vk_price_sqm = (
                tmpl.list_price / tmpl.vk_area_total
                if tmpl.vk_area_total else 0.0
            )

    @api.constrains('vk_area_total', 'vk_area_living', 'vk_area_balcony')
    def _check_vk_areas(self):
        for tmpl in self:
            if not tmpl.vk_is_unit:
                continue
            if tmpl.vk_area_total < 0 or tmpl.vk_area_living < 0 or tmpl.vk_area_balcony < 0:
                raise ValidationError(_("Areas cannot be negative."))
            if tmpl.vk_area_living and tmpl.vk_area_total \
                    and tmpl.vk_area_living > tmpl.vk_area_total:
                raise ValidationError(_(
                    "Living area (%(living)s m²) cannot exceed the total area "
                    "(%(total)s m²).",
                    living=tmpl.vk_area_living, total=tmpl.vk_area_total,
                ))
