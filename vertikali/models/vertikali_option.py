from odoo import fields, models


class VertikaliOption(models.Model):
    """A hand-managed value for a unit attribute (condition, window view).

    These were Selection fields, but the sales team names its own values --
    each project has its own renovation packages and its own views to sell --
    and a Selection cannot grow without a developer. One small model covers
    every such attribute; the `attribute` column keeps the lists apart.
    """

    _name = 'vertikali.option'
    _description = "Unit Attribute Value"
    _order = 'attribute, sequence, name'

    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)
    attribute = fields.Selection(
        selection=[
            ('condition', "Condition"),
            ('view', "View"),
        ],
        required=True,
        index=True,
        help="Which unit field this value belongs to.",
    )

    _sql_constraints = [
        ('name_attribute_uniq', 'unique(name, attribute)',
         "This value already exists for that attribute."),
    ]
