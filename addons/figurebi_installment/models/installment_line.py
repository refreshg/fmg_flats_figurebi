# -*- coding: utf-8 -*-
from odoo import api, fields, models


class FigurebiInstallmentLine(models.Model):
    # model/field names intentionally match the manual (x_) setup used on the
    # staging demo so views, reports and docs stay identical
    _name = "x_figurebi_installment_line"
    _description = "Installment Schedule Line"
    _order = "x_order_id, x_number, id"

    x_order_id = fields.Many2one(
        "sale.order", string="შეკვეთა", required=True, ondelete="cascade", index=True
    )
    x_number = fields.Integer(string="N", required=True)
    x_date = fields.Date(string="თარიღი", required=True)
    x_amount = fields.Float(string="თანხა")
    x_balance = fields.Float(
        string="ნაშთი",
        compute="_compute_balance",
        help="Remaining balance after this payment.",
    )
    x_is_weekend = fields.Boolean(
        string="შაბათ-კვირა",
        compute="_compute_is_weekend",
        help="Date falls on Saturday/Sunday and must be corrected.",
    )
    x_auto_fixed = fields.Boolean(
        string="ავტო-გასწორებული",
        help="Date was shifted off a weekend automatically; shown purple until edited manually.",
    )

    @api.depends("x_date")
    def _compute_is_weekend(self):
        for line in self:
            line.x_is_weekend = bool(line.x_date) and line.x_date.weekday() >= 5

    @api.depends("x_amount", "x_number", "x_order_id.amount_total",
                 "x_order_id.x_installment_line_ids.x_amount")
    def _compute_balance(self):
        for line in self:
            order = line.x_order_id
            paid = sum(
                l.x_amount or 0.0
                for l in order.x_installment_line_ids
                if (l.x_number or 0) <= (line.x_number or 0)
            )
            line.x_balance = round((order.amount_total or 0.0) - paid, 2)

    def write(self, vals):
        # a manual change of the date means the manager made their own choice:
        # drop the auto-fixed (purple) mark unless the auto-fix action itself writes
        if "x_date" in vals and not self.env.context.get("figurebi_autofix"):
            vals = dict(vals, x_auto_fixed=False)
        return super().write(vals)
