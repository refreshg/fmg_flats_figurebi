from odoo import _, api, fields, models
from odoo.exceptions import ValidationError

# How a scheme is worth less (or more) than the asking price. The team writes
# these two ways -- "10% off" and "$80 off the metre" -- and both are in use,
# so neither is expressed in terms of the other.
ADJUST_KIND = [
    ('pct', "პროცენტი"),
    ('amount', "თანხა"),
]
ADJUST_BASE = [
    ('sqm', "კვ.მ-ზე"),
    ('total', "ჯამურ თანხაზე"),
]


def apply_adjustment(base_price, base_sqm, area, kind, base, value):
    """Return ``(price, sqm)`` once the discount or markup is applied.

    One function, used by the calculation and by the floor check that holds it
    to its type, so the two can never come to different answers. A negative
    value takes off, a positive one adds on.

    ``base`` decides which of the two figures the discount is struck against
    and which one follows from it. Off the metre, the metre price is settled
    first and the flat costs that times its area; off the total, the reverse.
    The two need not agree to the cent, because the metre price a flat is
    listed at is a rounded figure.
    """
    base_price = base_price or 0.0
    base_sqm = base_sqm or 0.0
    value = value or 0.0
    if not value:
        return base_price, base_sqm
    if base == 'sqm':
        sqm = base_sqm * (1.0 + value / 100.0) if kind == 'pct' else base_sqm + value
        return (sqm * area if area else base_price + value), sqm
    price = base_price * (1.0 + value / 100.0) if kind == 'pct' else base_price + value
    return price, (price / area if area else base_sqm)


class VertikaliPaymentPlan(models.Model):
    """A payment schedule type, as the team writes it: 10/20/70.

    A model rather than a Selection for the same reason the unit attributes
    are one (decision D7 in vertikali): the terms on offer change with the
    season and the project, and the sales team has to be able to add one
    without a developer.
    """

    _name = 'vertikali.payment.plan'
    _description = "Payment Schedule Type"
    _order = 'sequence, id'

    name = fields.Char(
        string="დასახელება", required=True,
        help="How the team says it, e.g. 10/20/70.")
    sequence = fields.Integer(default=10)
    active = fields.Boolean(string="აქტიური", default=True)

    first_pct = fields.Float(
        string="პირველადი %", digits=(5, 2), required=True)
    mid_pct = fields.Float(
        string="განვადების %", digits=(5, 2), required=True,
        help="Split evenly across the instalment period.")
    last_pct = fields.Float(
        string="ბოლო %", digits=(5, 2), required=True)

    # Signed throughout: minus takes off, plus adds on. One number rather than
    # a discount field and a markup field, which would leave open what a
    # record with both filled in was supposed to mean. Kind and base are
    # independent: a percentage or a sum, struck against the metre or against
    # the whole flat, and all four combinations are in use.
    adjust_kind = fields.Selection(
        selection=ADJUST_KIND, string="ფასდაკლების ტიპი",
        required=True, default='pct')
    adjust_base = fields.Selection(
        selection=ADJUST_BASE, string="ფასდაკლების სახე",
        required=True, default='sqm')
    adjust_value = fields.Float(
        string="ფასდაკლება", digits=(12, 2),
        help="Minus discounts, plus adds on.")

    note = fields.Char(string="შენიშვნა")

    @api.constrains('first_pct', 'mid_pct', 'last_pct')
    def _check_pct(self):
        for plan in self:
            total = plan.first_pct + plan.mid_pct + plan.last_pct
            if abs(total - 100.0) > 0.01:
                raise ValidationError(_(
                    "The three parts must add up to 100%%. "
                    "%(name)s adds up to %(total)s.",
                    name=plan.name, total=round(total, 2)))
            if min(plan.first_pct, plan.mid_pct, plan.last_pct) < 0:
                raise ValidationError(_("A share cannot be negative."))

    @api.constrains('adjust_kind', 'adjust_value')
    def _check_adjust(self):
        for plan in self:
            if plan.adjust_kind == 'pct' and plan.adjust_value <= -100.0:
                raise ValidationError(_(
                    "A discount of 100%% or more would leave nothing to pay."))

    def apply_to(self, base_price, base_sqm, area):
        """What this type makes of a given asking price."""
        self.ensure_one()
        return apply_adjustment(base_price, base_sqm, area,
                                self.adjust_kind, self.adjust_base,
                                self.adjust_value)
