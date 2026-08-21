#!/bin/bash
# Recreates the vertikali module under /tmp, then installs it.
set -e
rm -rf /tmp/vertikali
mkdir -p /tmp/vertikali/models /tmp/vertikali/security /tmp/vertikali/views

cat > /tmp/vertikali/models/product_template.py <<'VKEOF'
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
VKEOF

cat > /tmp/vertikali/models/__init__.py <<'VKEOF'
from . import product_template
VKEOF

cat > /tmp/vertikali/security/ir.model.access.csv <<'VKEOF'
id,name,model_id:id,group_id:id,perm_read,perm_write,perm_create,perm_unlink
VKEOF

cat > /tmp/vertikali/views/menus.xml <<'VKEOF'
<?xml version="1.0" encoding="utf-8"?>
<odoo>

    <!-- Top-level app. Restricted to the sales team: this is an internal tool. -->
    <menuitem id="menu_vertikali_root"
              name="Estate"
              groups="sales_team.group_sale_salesman"
              sequence="15"/>

    <menuitem id="menu_vertikali_inventory"
              name="Inventory"
              parent="menu_vertikali_root"
              sequence="10"/>

    <menuitem id="menu_vertikali_units"
              name="Units"
              parent="menu_vertikali_inventory"
              action="action_vertikali_units"
              sequence="10"/>

    <menuitem id="menu_vertikali_categories"
              name="Projects &amp; Buildings"
              parent="menu_vertikali_inventory"
              action="action_vertikali_categories"
              groups="sales_team.group_sale_manager"
              sequence="20"/>

</odoo>
VKEOF

cat > /tmp/vertikali/views/product_template_views.xml <<'VKEOF'
<?xml version="1.0" encoding="utf-8"?>
<odoo>

    <!-- Form: apartment data on its own notebook page, shown only for units. -->
    <record id="view_product_template_form_vertikali" model="ir.ui.view">
        <field name="name">product.template.form.vertikali</field>
        <field name="model">product.template</field>
        <field name="inherit_id" ref="product.product_template_form_view"/>
        <field name="arch" type="xml">

            <!-- The flag lives next to sale_ok so it reads as a product-kind switch. -->
            <xpath expr="//div[@name='options']" position="inside">
                <span name="vk_unit_option" class="d-inline-flex">
                    <field name="vk_is_unit"/>
                    <label for="vk_is_unit"/>
                </span>
            </xpath>

            <xpath expr="//notebook" position="inside">
                <page string="Unit" name="vertikali_unit" invisible="not vk_is_unit">
                    <group>
                        <group string="Location" name="vk_location">
                            <field name="vk_building" placeholder="e.g. A"/>
                            <field name="vk_floor"/>
                            <field name="vk_rooms"/>
                            <field name="vk_orientation"/>
                        </group>
                        <group string="Areas" name="vk_areas">
                            <field name="vk_area_total"/>
                            <field name="vk_area_living"/>
                            <field name="vk_area_balcony"/>
                        </group>
                        <group string="Commercial" name="vk_commercial">
                            <field name="vk_price_sqm"/>
                            <field name="vk_handover"/>
                        </group>
                    </group>
                </page>
            </xpath>
        </field>
    </record>

    <!-- List: the inventory screen from the approved mockup (1g). -->
    <record id="view_product_template_list_vertikali" model="ir.ui.view">
        <field name="name">product.template.list.vertikali</field>
        <field name="model">product.template</field>
        <field name="inherit_id" ref="product.product_template_tree_view"/>
        <field name="arch" type="xml">
            <xpath expr="//field[@name='default_code']" position="after">
                <field name="vk_building" optional="show"/>
                <field name="vk_floor" optional="show"/>
                <field name="vk_rooms" optional="show"/>
                <field name="vk_area_total" optional="show" sum="Total m²"/>
                <field name="vk_price_sqm" optional="show"/>
            </xpath>
        </field>
    </record>

    <!-- Search: the filters the sales team actually uses. -->
    <record id="view_product_template_search_vertikali" model="ir.ui.view">
        <field name="name">product.template.search.vertikali</field>
        <field name="model">product.template</field>
        <field name="inherit_id" ref="product.product_template_search_view"/>
        <field name="arch" type="xml">
            <xpath expr="//search" position="inside">
                <separator/>
                <filter name="vk_units" string="Units"
                        domain="[('vk_is_unit', '=', True)]"/>
                <group expand="0" string="Unit Grouping">
                    <filter name="vk_group_building" string="Building"
                            context="{'group_by': 'vk_building'}"/>
                    <filter name="vk_group_floor" string="Floor"
                            context="{'group_by': 'vk_floor'}"/>
                    <filter name="vk_group_rooms" string="Layout"
                            context="{'group_by': 'vk_rooms'}"/>
                </group>
            </xpath>
        </field>
    </record>

    <!-- Action scoped to units so the Estate menu never shows ordinary products. -->
    <record id="action_vertikali_units" model="ir.actions.act_window">
        <field name="name">Units</field>
        <field name="res_model">product.template</field>
        <field name="view_mode">list,kanban,form</field>
        <field name="domain">[('vk_is_unit', '=', True)]</field>
        <field name="context">{'default_vk_is_unit': True, 'default_type': 'consu'}</field>
        <field name="help" type="html">
            <p class="o_view_nocontent_smiling_face">Create your first unit</p>
            <p>Apartments are standard products flagged as units, so they reuse
               pricing, inventory and the quotation flow.</p>
        </field>
    </record>

    <!-- Project / building hierarchy reuses product categories. -->
    <record id="action_vertikali_categories" model="ir.actions.act_window">
        <field name="name">Projects &amp; Buildings</field>
        <field name="res_model">product.category</field>
        <field name="view_mode">list,form</field>
    </record>

</odoo>
VKEOF

cat > /tmp/vertikali/__init__.py <<'VKEOF'
from . import models
VKEOF

cat > /tmp/vertikali/__manifest__.py <<'VKEOF'
{
    'name': "ვერტიკალი — Real Estate Units",
    'summary': "Apartment inventory and visual unit selector for developers",
    'description': """
Vertikali — Real Estate Sales
=============================

Manages apartment inventory for property developers as standard Odoo products,
with a visual unit selector (facade -> floor -> unit) for the sales team.

Built standard-first: units are ``product.template`` records, the sales flow is
the stock CRM opportunity -> quotations -> sales order chain. Only the
apartment-specific fields and the visual selector are custom.
    """,
    'author': "Vertikali",
    'category': 'Sales',
    'version': '19.0.1.0.0',
    'license': 'LGPL-3',

    # crm/sale_crm give us the opportunity -> multiple quotations flow (D6),
    # stock gives per-unit availability. All verified installed on the target DB.
    'depends': [
        'base',
        'product',
        'sale_management',
        'crm',
        'sale_crm',
        'stock',
        'mail',
    ],

    'data': [
        'security/ir.model.access.csv',
        'views/product_template_views.xml',
        'views/menus.xml',
    ],

    'installable': True,
    'application': True,
}
VKEOF

echo "--- files written ---"
find /tmp/vertikali -type f | sort
