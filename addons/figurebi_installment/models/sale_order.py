# -*- coding: utf-8 -*-
from datetime import date

from dateutil.relativedelta import relativedelta

from odoo import api, fields, models
from odoo.exceptions import UserError


PERIODICITY = [
    ("1", "თვეში ერთხელ"),
    ("2", "ორ თვეში ერთხელ"),
    ("3", "სამ თვეში ერთხელ"),
    ("6", "ექვს თვეში ერთხელ"),
    ("12", "წელიწადში ერთხელ"),
]


class SaleOrder(models.Model):
    _inherit = "sale.order"

    # ------------------------------------------------------------------ inputs
    x_payment_type = fields.Selection(
        selection=[
            ("installment", "შიდა განვადება"),
            ("bank_loan", "ბანკის სესხი"),
            ("full_payment", "ერთიანი გადახდა"),
        ],
        string="გადახდის ტიპი",
        default="installment",
    )
    x_periodicity = fields.Selection(PERIODICITY, string="გადახდის პერიოდულობა", default="1")
    x_schedule_months = fields.Integer(
        string="გადანაწილების ვადა (თვე)",
        help="How many months to spread the schedule part over. Empty/0 = automatic, until project completion.",
    )
    x_first_payment_date = fields.Date(string="პირველადი შენატანის თარიღი")
    x_schedule_start_date = fields.Date(string="განვადების დაწყების თარიღი")
    x_final_payment_date = fields.Date(
        string="ბოლო გადახდის თარიღი",
        help="Empty = automatic (the 15th of the completion month).",
    )
    x_project_end_date = fields.Date(string="პროექტის დასრულების თარიღი")
    x_bank_transfer_date = fields.Date(
        string="სესხის ჩარიცხვის თარიღი",
        help="Empty = same day as the co-participation payment.",
    )

    # tranche / balloon: both $ and % enterable, kept in sync
    x_first_tranche_pct = fields.Float(string="პირველადი შენატანი (%)", default=10.0, digits=(16, 4))
    x_first_tranche_amount = fields.Float(string="პირველადი შენატანი ($)", digits=(16, 4))
    x_final_balloon_pct = fields.Float(string="ბოლო შენატანი (%)", default=80.0, digits=(16, 4))
    x_final_balloon_amount = fields.Float(string="ბოლო შენატანი ($)", digits=(16, 4))

    # discount / markup: %, $ per m2 or total $, synced to the line's Disc.%
    x_discount_pct = fields.Float(string="ფასდაკლება / ფასნამატი (%)", digits=(16, 4))
    x_discount_per_m2 = fields.Float(string="ფასდაკლება / ფასნამატი კვ.მ ($)", digits=(16, 4))
    x_discount_total = fields.Float(string="ფასდაკლება / ფასნამატი სრული ($)", digits=(16, 4))

    # bank reference
    x_bank_rate = fields.Float(string="საბანკო განაკვეთი %", default=14.0)
    x_bank_term_months = fields.Integer(string="სესხის ვადა (თვე)", default=120)

    x_installment_line_ids = fields.One2many(
        "x_figurebi_installment_line", "x_order_id", string="გადახდის გრაფიკი", copy=False
    )
    x_schedule_snapshot = fields.Char(string="გრაფიკის snapshot", copy=False)

    # ---------------------------------------------------------------- computed
    x_object_ref = fields.Char(string="უძრავი ქონების № / მ²", compute="_compute_header")
    x_price_per_m2 = fields.Float(string="საწყისი კვ.მ ღირებულება", compute="_compute_header", digits=(16, 4))
    x_initial_total = fields.Float(string="საწყისი ჯამური ღირებულება", compute="_compute_header", digits=(16, 4))
    x_final_price_per_m2 = fields.Float(
        string="საბოლოო კვ.მ ფასი",
        compute="_compute_final_price_per_m2",
        inverse="_inverse_final_price_per_m2",
        store=True,
        readonly=False,
        digits=(16, 4),
    )
    x_final_total = fields.Float(
        string="საბოლოო ფასი ($)",
        compute="_compute_final_total",
        inverse="_inverse_final_total",
        store=True,
        readonly=False,
        digits=(16, 4),
    )
    x_schedule_pct = fields.Float(string="გრაფიკით გადაიხდის %", compute="_compute_schedule_part", digits=(16, 4))
    x_schedule_amount = fields.Float(string="გრაფიკით გადაიხდის ($)", compute="_compute_schedule_part", digits=(16, 4))
    x_bank_loan_amount = fields.Float(string="სესხის თანხა", compute="_compute_bank")
    x_bank_pmt_reference = fields.Float(
        string="საბანკო შენატანი (საცნობარო)",
        compute="_compute_bank",
        help="Estimated monthly bank payment (annuity), informational only.",
    )
    x_schedule_end_date = fields.Date(
        string="გრაფიკის ბოლო შენატანი (ავტო)",
        compute="_compute_schedule_end",
        help="The exact date of the last schedule installment (predicted from the spread before generation).",
    )
    x_has_weekend = fields.Boolean(compute="_compute_has_weekend")
    x_schedule_stale = fields.Boolean(string="გრაფიკი მოძველებულია", compute="_compute_stale")
    x_installment_invoice_count = fields.Integer(
        string="განვადების ინვოისები", compute="_compute_invoice_count"
    )

    # ------------------------------------------------------------------ helpers
    def _figurebi_main_line(self):
        self.ensure_one()
        return self.order_line.filtered(lambda l: not l.display_type)[:1]

    @api.model
    def _figurebi_unit_area(self, line):
        """The flat's area in m², wherever the database records it.

        figurebi's own x_area first; then vertikali's vk_area_total, where
        that module is installed; failing both, the ordered quantity, which
        is the area under figurebi's convention of pricing per m².
        """
        if not line:
            return 0.0
        tmpl = line.product_id.product_tmpl_id if line.product_id else None
        area = 0.0
        if tmpl:
            area = tmpl.x_area or getattr(tmpl, "vk_area_total", 0.0) or 0.0
        return area or line.product_uom_qty or 0.0

    @api.model
    def _figurebi_price_per_m2(self, line):
        """Asking price per m² of the main unit, before discount.

        The line total divided by the area, so it reads the same whether
        the line is priced per m² (qty = area) or per flat (qty = 1).
        """
        if not line:
            return 0.0
        area = self._figurebi_unit_area(line)
        gross = (line.price_unit or 0.0) * (line.product_uom_qty or 0.0)
        return round(gross / area, 4) if area else (line.price_unit or 0.0)

    def _figurebi_gross(self):
        """Asking price of the whole order: before discount, before tax."""
        self.ensure_one()
        return sum(
            (l.price_unit or 0.0) * (l.product_uom_qty or 0.0)
            for l in self.order_line.filtered(lambda l: not l.display_type)
        )

    def _figurebi_gross_incl_tax(self):
        """What amount_total would be at 0% discount.

        amount_total carries tax. Comparing it with the untaxed asking price
        read a 5% discount back as a 5.66% markup on any order with a taxed
        line, and the percentage the user had just typed was overwritten.
        Each line is scaled back by its own discount, so percentage taxes
        are accounted for exactly.
        """
        self.ensure_one()
        total = 0.0
        for l in self.order_line.filtered(lambda l: not l.display_type):
            factor = 1.0 - (l.discount or 0.0) / 100.0
            total += (l.price_total or 0.0) / factor if factor else 0.0
        return total

    def _figurebi_pct_from_final_total(self):
        """The discount % that yields x_final_total, or None if it cannot be told."""
        self.ensure_one()
        gross = self._figurebi_gross_incl_tax()
        if not gross:
            return None
        return round((1 - (self.x_final_total or 0.0) / gross) * 100.0, 6)

    def _figurebi_final_total_reached(self):
        """Whether the current discount already lands on x_final_total (±1 cent).

        The damper for knock-on onchange/inverse rounds: comparing in currency
        rather than in % keeps a typed 4-decimal percentage from being
        overwritten while still letting cent-level total edits through.
        """
        self.ensure_one()
        gross = self._figurebi_gross_incl_tax()
        achieved = gross * (1 - (self.x_discount_pct or 0.0) / 100.0)
        return abs(achieved - (self.x_final_total or 0.0)) < 0.011

    def _figurebi_signature(self):
        self.ensure_one()
        return "|".join([
            str(self.x_payment_type or ""),
            str(round(self.x_first_tranche_amount or 0.0, 2)),
            str(round(self.x_final_balloon_amount or 0.0, 2)),
            str(self.x_first_payment_date or ""),
            str(self.x_schedule_start_date or ""),
            str(self.x_periodicity or 1),
            str(self.x_schedule_months or 0),
            str(self.x_final_payment_date or ""),
            str(self.x_bank_transfer_date or ""),
            str(self.x_project_end_date or ""),
            str(round(self.amount_total or 0.0, 2)),
        ])

    # ----------------------------------------------------------------- computes
    @api.depends("order_line.product_id", "order_line.product_uom_qty",
                 "order_line.price_unit", "order_line.discount")
    def _compute_header(self):
        for order in self:
            line = order._figurebi_main_line()
            if line and line.product_id:
                order.x_object_ref = "%s / %g მ²" % (
                    line.product_id.default_code or line.product_id.name,
                    order._figurebi_unit_area(line),
                )
            else:
                order.x_object_ref = ""
            order.x_price_per_m2 = order._figurebi_price_per_m2(line)
            order.x_initial_total = round(sum(
                (l.price_unit or 0.0) * (l.product_uom_qty or 0.0)
                for l in order.order_line.filtered(lambda l: not l.display_type)
            ), 4)

    @api.depends("order_line.price_unit", "order_line.discount")
    def _compute_final_price_per_m2(self):
        for order in self:
            line = order._figurebi_main_line()
            order.x_final_price_per_m2 = round(
                order._figurebi_price_per_m2(line) * (1 - (line.discount or 0.0) / 100.0), 4
            ) if line else 0.0

    @api.depends("amount_total")
    def _compute_final_total(self):
        for order in self:
            order.x_final_total = order.amount_total or 0.0

    def _set_discount_from_pct(self, pct, line):
        # keep all discount cards in sync and push pct to the order lines;
        # the total is the whole order's, the per-m2 figure the main unit's
        self.x_discount_pct = pct
        self.x_discount_per_m2 = round(self._figurebi_price_per_m2(line) * pct / 100.0, 4)
        self.x_discount_total = round(self._figurebi_gross() * pct / 100.0, 4)
        self._apply_discount_pct(pct)

    def _inverse_final_price_per_m2(self):
        for order in self:
            line = order._figurebi_main_line()
            per_m2 = order._figurebi_price_per_m2(line)
            if not line or not per_m2:
                continue
            achieved = per_m2 * (1 - (order.x_discount_pct or 0.0) / 100.0)
            if abs(achieved - (order.x_final_price_per_m2 or 0.0)) < 0.011:
                continue
            pct = round((1 - (order.x_final_price_per_m2 or 0.0) / per_m2) * 100.0, 6)
            order._set_discount_from_pct(pct, line)

    def _inverse_final_total(self):
        for order in self:
            line = order._figurebi_main_line()
            if not line or not line.price_unit or not line.product_uom_qty:
                continue
            pct = order._figurebi_pct_from_final_total()
            if pct is None or order._figurebi_final_total_reached():
                continue
            order._set_discount_from_pct(pct, line)

    @api.depends("x_first_tranche_pct", "x_final_balloon_pct",
                 "amount_total", "x_first_tranche_amount", "x_final_balloon_amount")
    def _compute_schedule_part(self):
        for order in self:
            order.x_schedule_pct = round(max(
                0.0, 100.0 - (order.x_first_tranche_pct or 0.0) - (order.x_final_balloon_pct or 0.0)
            ), 4)
            order.x_schedule_amount = round(
                (order.amount_total or 0.0)
                - (order.x_first_tranche_amount or 0.0)
                - (order.x_final_balloon_amount or 0.0), 2
            )

    @api.depends("amount_total", "x_payment_type", "x_first_tranche_amount",
                 "x_final_balloon_amount", "x_bank_rate", "x_bank_term_months")
    def _compute_bank(self):
        for order in self:
            total = order.amount_total or 0.0
            if (order.x_payment_type or "") == "bank_loan":
                order.x_bank_loan_amount = round(total - (order.x_first_tranche_amount or 0.0), 2)
                principal = order.x_bank_loan_amount
            else:
                order.x_bank_loan_amount = 0.0
                principal = order.x_final_balloon_amount or 0.0
            months = order.x_bank_term_months or 0
            rate = (order.x_bank_rate or 0.0) / 100.0 / 12.0
            if principal <= 0 or months <= 0:
                order.x_bank_pmt_reference = 0.0
            elif rate:
                order.x_bank_pmt_reference = round(principal * rate / (1 - (1 + rate) ** -months), 2)
            else:
                order.x_bank_pmt_reference = round(principal / months, 2)

    @api.depends("x_installment_line_ids.x_date", "x_schedule_start_date",
                 "x_schedule_months", "x_periodicity", "x_payment_type",
                 "x_final_balloon_amount")
    def _compute_schedule_end(self):
        for order in self:
            lines = order.x_installment_line_ids.sorted(key=lambda l: l.x_number or 0)
            # the balloon payment is the last row but not a schedule installment
            if (lines and len(lines) > 1
                    and (order.x_payment_type or "installment") == "installment"
                    and (order.x_final_balloon_amount or 0.0) > 0.005):
                lines = lines[:-1]
            dates = [d for d in lines.mapped("x_date") if d]
            if dates:
                order.x_schedule_end_date = max(dates)
            elif order.x_schedule_start_date and (order.x_schedule_months or 0) > 0:
                interval = int(order.x_periodicity or 1)
                count = max(1, int(order.x_schedule_months) // interval)
                order.x_schedule_end_date = order.x_schedule_start_date + relativedelta(
                    months=(count - 1) * interval
                )
            else:
                order.x_schedule_end_date = False

    @api.depends("x_installment_line_ids.x_date")
    def _compute_has_weekend(self):
        for order in self:
            order.x_has_weekend = any(
                d and d.weekday() >= 5
                for d in order.x_installment_line_ids.mapped("x_date")
            )

    @api.depends("x_payment_type", "x_first_tranche_amount", "x_final_balloon_amount",
                 "x_first_payment_date", "x_schedule_start_date", "x_periodicity",
                 "x_schedule_months", "x_final_payment_date", "x_bank_transfer_date",
                 "x_project_end_date", "amount_total", "x_schedule_snapshot",
                 "x_installment_line_ids.x_amount")
    def _compute_stale(self):
        for order in self:
            lines = order.x_installment_line_ids
            mismatch = bool(lines) and abs(
                sum(lines.mapped("x_amount")) - (order.amount_total or 0.0)
            ) > 0.01
            order.x_schedule_stale = bool(lines) and (
                (order.x_schedule_snapshot or "") != order._figurebi_signature() or mismatch
            )

    def _compute_invoice_count(self):
        for order in self:
            order.x_installment_invoice_count = self.env["account.move"].search_count([
                ("invoice_origin", "=", order.name),
                ("move_type", "=", "out_invoice"),
                ("state", "!=", "cancel"),
            ]) if order.name else 0

    # ----------------------------------------------------- live sync (onchange)
    @api.onchange("x_first_tranche_pct", "x_final_balloon_pct", "order_line")
    def _onchange_pcts(self):
        total = self.amount_total or 0.0
        self.x_first_tranche_amount = round(total * (self.x_first_tranche_pct or 0.0) / 100.0, 4)
        self.x_final_balloon_amount = round(total * (self.x_final_balloon_pct or 0.0) / 100.0, 4)

    @api.onchange("x_first_tranche_amount")
    def _onchange_first_amount(self):
        total = self.amount_total or 0.0
        if total:
            self.x_first_tranche_pct = round((self.x_first_tranche_amount or 0.0) / total * 100.0, 4)

    @api.onchange("x_final_balloon_amount")
    def _onchange_balloon_amount(self):
        total = self.amount_total or 0.0
        if total:
            self.x_final_balloon_pct = round((self.x_final_balloon_amount or 0.0) / total * 100.0, 4)

    def _apply_discount_pct(self, pct):
        if pct > 100:
            raise UserError("ფასდაკლება მთლიან ფასს ვერ გადააჭარბებს (მინუსი = ფასნამატი).")
        for line in self.order_line.filtered(lambda l: not l.display_type):
            line.discount = pct

    @api.onchange("x_discount_pct")
    def _onchange_discount_pct(self):
        line = self._figurebi_main_line()
        if not line or not line.price_unit or not line.product_uom_qty:
            return
        pct = self.x_discount_pct or 0.0
        self.x_discount_total = round(self._figurebi_gross() * pct / 100.0, 4)
        self.x_discount_per_m2 = round(self._figurebi_price_per_m2(line) * pct / 100.0, 4)
        self._apply_discount_pct(pct)

    @api.onchange("x_discount_per_m2")
    def _onchange_discount_per_m2(self):
        line = self._figurebi_main_line()
        if not line or not line.price_unit or not line.product_uom_qty:
            return
        per_m2 = self.x_discount_per_m2 or 0.0
        price_per_m2 = self._figurebi_price_per_m2(line)
        if not price_per_m2:
            return
        pct = round(per_m2 / price_per_m2 * 100.0, 6)
        self.x_discount_total = round(self._figurebi_gross() * pct / 100.0, 4)
        self.x_discount_pct = pct
        self._apply_discount_pct(pct)

    @api.onchange("x_discount_total")
    def _onchange_discount_total(self):
        line = self._figurebi_main_line()
        if not line or not line.price_unit or not line.product_uom_qty:
            return
        total_d = self.x_discount_total or 0.0
        gross = self._figurebi_gross()
        pct = round(total_d / gross * 100.0, 6) if gross else 0.0
        self.x_discount_per_m2 = round(self._figurebi_price_per_m2(line) * pct / 100.0, 4)
        self.x_discount_pct = pct
        self._apply_discount_pct(pct)

    @api.onchange("x_final_price_per_m2")
    def _onchange_final_price_per_m2(self):
        # Also fires as a knock-on when a typed % moves the line discount,
        # so it must come back to the same % and leave it alone when it does.
        line = self._figurebi_main_line()
        per_m2 = self._figurebi_price_per_m2(line)
        if not line or not per_m2:
            return
        achieved = per_m2 * (1 - (self.x_discount_pct or 0.0) / 100.0)
        if abs(achieved - (self.x_final_price_per_m2 or 0.0)) < 0.011:
            return
        pct = round((1 - (self.x_final_price_per_m2 or 0.0) / per_m2) * 100.0, 6)
        self._set_discount_from_pct(pct, line)

    @api.onchange("x_final_total")
    def _onchange_final_total(self):
        # Also fires as a knock-on when a typed % moves amount_total, so it
        # must come back to the same % and leave it alone when it does.
        line = self._figurebi_main_line()
        if not line or not line.price_unit or not line.product_uom_qty:
            return
        pct = self._figurebi_pct_from_final_total()
        if pct is None or self._figurebi_final_total_reached():
            return
        self._set_discount_from_pct(pct, line)

    @api.onchange("x_schedule_months", "x_schedule_start_date", "x_periodicity")
    def _onchange_spread(self):
        # place the final (balloon) payment one interval after the last installment
        if (self.x_payment_type or "installment") != "installment":
            return
        months = int(self.x_schedule_months or 0)
        if months > 0 and self.x_schedule_start_date:
            interval = int(self.x_periodicity or 1)
            count = max(1, months // interval)
            self.x_final_payment_date = self.x_schedule_start_date + relativedelta(
                months=count * interval
            )

    # ------------------------------------------------------- write-level guards
    def write(self, vals):
        if vals.get("state") in ("sent", "sale"):
            for order in self:
                bad = order.x_installment_line_ids.filtered(lambda l: l.x_is_weekend)
                if bad:
                    raise UserError(
                        "შემდეგ ეტაპზე გადასვლა შეუძლებელია: გრაფიკში შაბათ-კვირის (წითელი) "
                        "თარიღებია: %s. ჯერ შეასწორეთ (ღილაკით ან ხელით)."
                        % ", ".join(str(d) for d in bad.mapped("x_date"))
                    )
        return super().write(vals)

    # ------------------------------------------------------- schedule generation
    def action_generate_schedule(self):
        for order in self:
            total = order.amount_total
            if total <= 0:
                raise UserError("ჯამური ფასი უნდა იყოს 0-ზე მეტი — ჯერ დაამატეთ ობიექტი შეკვეთის ხაზებში.")
            if not order.x_first_payment_date:
                raise UserError("შეავსეთ პირველადი შენატანის თარიღი.")
            ptype = order.x_payment_type or "installment"
            order.x_installment_line_ids.unlink()
            vals_list = []
            if ptype == "full_payment":
                vals_list.append(order._line_vals(1, order.x_first_payment_date, total))
            elif ptype == "bank_loan":
                # Excel-style split: co-participation (client) + loan amount (bank)
                first_amt = round(order.x_first_tranche_amount or 0.0, 2)
                if first_amt < 0 or first_amt > total:
                    raise UserError("თანამონაწილეობა 0-სა და ჯამურ ფასს შორის უნდა იყოს.")
                loan = round(total - first_amt, 2)
                num = 1
                if first_amt > 0.005:
                    vals_list.append(order._line_vals(num, order.x_first_payment_date, first_amt))
                    num += 1
                if loan > 0.005:
                    vals_list.append(order._line_vals(
                        num, order.x_bank_transfer_date or order.x_first_payment_date, loan
                    ))
            else:
                vals_list += order._installment_vals(total)
            self.env["x_figurebi_installment_line"].create(vals_list)
            order.x_schedule_snapshot = order._figurebi_signature()
        return True

    def _line_vals(self, number, line_date, amount):
        return {"x_order_id": self.id, "x_number": number, "x_date": line_date, "x_amount": amount}

    def _installment_vals(self, total):
        self.ensure_one()
        first_amt = round(self.x_first_tranche_amount or 0.0, 2)
        balloon_amt = round(self.x_final_balloon_amount or 0.0, 2)
        if first_amt < 0 or balloon_amt < 0:
            raise UserError("თანხები უარყოფითი ვერ იქნება.")
        sched_amt = round(total - first_amt - balloon_amt, 2)
        if sched_amt < -0.01:
            raise UserError("პირველადი შენატანი + ბოლო გადახდა ჯამურ ფასს აჭარბებს.")
        if not self.x_schedule_start_date or not self.x_project_end_date:
            raise UserError("შეავსეთ განვადების დაწყებისა და პროექტის დასრულების თარიღები.")
        if self.x_schedule_start_date > self.x_project_end_date:
            raise UserError("განვადების დაწყების თარიღი პროექტის დასრულებაზე გვიან ვერ იქნება.")
        interval = int(self.x_periodicity or 1)
        cap = date(self.x_project_end_date.year, self.x_project_end_date.month, 15)
        bdate = self.x_final_payment_date or cap
        if bdate > self.x_project_end_date:
            raise UserError(
                "ბოლო გადახდის თარიღი (%s) პროექტის დასრულების თარიღზე (%s) გვიან ვერ იქნება."
                % (bdate, self.x_project_end_date)
            )
        vals_list = [self._line_vals(1, self.x_first_payment_date, first_amt)]
        months = int(self.x_schedule_months or 0)
        dates = []
        if months > 0:
            count = max(1, months // interval)
            for k in range(count):
                dates.append(self.x_schedule_start_date + relativedelta(months=k * interval))
            if dates[-1] > self.x_project_end_date:
                raise UserError("გადანაწილების ვადა (%s თვე) სცდება პროექტის დასრულებას." % months)
        else:
            k = 0
            while True:
                d = self.x_schedule_start_date + relativedelta(months=k * interval)
                if d > self.x_project_end_date or d >= cap:
                    break
                dates.append(d)
                k += 1
        # a schedule installment in the balloon's own month is folded away: the
        # client must not pay twice in the final month, the remaining
        # installments grow to cover the same schedule amount (user rule)
        if balloon_amt > 0.005 and dates and (dates[-1].year, dates[-1].month) == (bdate.year, bdate.month):
            dates.pop()
        if balloon_amt > 0.005 and dates and bdate <= dates[-1]:
            raise UserError(
                "ბოლო გადახდის თარიღი (%s) გრაფიკის ბოლო შენატანზე (%s) გვიან უნდა იყოს."
                % (bdate, dates[-1])
            )
        n = len(dates)
        if sched_amt > 0.005:
            if n < 1:
                raise UserError("თარიღების მიხედვით გრაფიკში შენატანი ვერ თავსდება — შეამოწმეთ თარიღები/პერიოდულობა.")
            per = round(sched_amt / n, 2)
            acc = 0.0
            for i, d in enumerate(dates):
                # last schedule row absorbs rounding so the schedule part is exact
                amt = per if i < n - 1 else round(sched_amt - acc, 2)
                acc = round(acc + amt, 2)
                vals_list.append(self._line_vals(i + 2, d, amt))
        if balloon_amt > 0.005:
            vals_list.append(self._line_vals(len(vals_list) + 1, bdate, balloon_amt))
        return vals_list

    # -------------------------------------------------------- weekend auto-fix
    def action_fix_weekends(self):
        for order in self:
            bad = order.x_installment_line_ids.filtered(lambda l: l.x_is_weekend)
            if not bad:
                raise UserError("წითელი (შაბათ-კვირის) თარიღები არ არის — გასასწორებელი არაფერია.")
            for line in bad:
                shift = 2 if line.x_date.weekday() == 5 else 1
                line.with_context(figurebi_autofix=True).write({
                    "x_date": line.x_date + relativedelta(days=shift),
                    "x_auto_fixed": True,
                })
        return True

    # ------------------------------------------------------- invoice generation
    def action_generate_invoices(self):
        for order in self:
            if order.state != "sale":
                raise UserError("ინვოისების გენერაცია მხოლოდ დადასტურებულ შეკვეთაზეა შესაძლებელი — ჯერ დაადასტურეთ (Confirm) შეთავაზება.")
            lines = order.x_installment_line_ids.sorted(key=lambda l: l.x_number)
            if not lines:
                raise UserError("ჯერ დააგენერირეთ გადახდის გრაფიკი.")
            bad = lines.filtered(lambda l: l.x_is_weekend)
            if bad:
                raise UserError(
                    "გრაფიკში შაბათ-კვირის (წითელი) თარიღებია: %s. ჯერ შეასწორეთ და მერე გამოწერეთ ინვოისები."
                    % ", ".join(str(d) for d in bad.mapped("x_date"))
                )
            existing = self.env["account.move"].search_count([
                ("invoice_origin", "=", order.name),
                ("move_type", "=", "out_invoice"),
                ("state", "!=", "cancel"),
            ])
            if existing:
                raise UserError(
                    "ამ შეკვეთაზე ინვოისები უკვე არსებობს (%s ცალი). ჯერ გააუქმეთ/წაშალეთ ისინი Accounting-ში." % existing
                )
            product = self.env.ref("figurebi_installment.product_installment_fee", raise_if_not_found=False)
            if not product:
                raise UserError("ვერ მოიძებნა პროდუქტი „განვადების შენატანი“ — მოდული ხელახლა დააინსტალირეთ.")
            total_count = len(lines)
            for line in lines:
                self.env["account.move"].create({
                    "move_type": "out_invoice",
                    "partner_id": order.partner_id.id,
                    "currency_id": order.currency_id.id,
                    "invoice_origin": order.name,
                    "invoice_date_due": line.x_date,
                    "invoice_payment_term_id": False,
                    "invoice_user_id": order.user_id.id,
                    "invoice_line_ids": [(0, 0, {
                        "product_id": product.product_variant_id.id,
                        "name": "განვადების შენატანი %s/%s — %s" % (line.x_number, total_count, order.name),
                        "quantity": 1,
                        "price_unit": line.x_amount,
                        "tax_ids": [(6, 0, [])],
                    })],
                })
        return True

    def action_view_installment_invoices(self):
        self.ensure_one()
        return {
            "type": "ir.actions.act_window",
            "name": "განვადების ინვოისები",
            "res_model": "account.move",
            "view_mode": "list,form",
            "domain": [("invoice_origin", "=", self.name), ("move_type", "=", "out_invoice")],
        }
