from dateutil.relativedelta import relativedelta

from odoo import _, api, fields, models
from odoo.exceptions import UserError, ValidationError

from .payment_plan import ADJUST_BASE, ADJUST_KIND, apply_adjustment

# Overridable without a deploy, through Settings > Technical > System
# Parameters. The legacy key is still read: the calculator shipped inside
# vertikali_crm_config before it was a module of its own, and a rate already
# entered there should not silently revert.
NBG_PARAM = 'vertikali_payment_calc.nbg_usd'
NBG_LEGACY_PARAM = 'vertikali_crm_config.nbg_usd'
NBG_DEFAULT = 2.7178

# Read off the flat where an estate module provides them. Named here rather
# than reached for inline, so what this module expects of its host is one
# short list in one place.
UNIT_AREA_FIELD = 'vk_area_total'
UNIT_SQM_PRICE_FIELD = 'vk_price_sqm'


class VertikaliPaymentCalc(models.Model):
    """One worked-out payment schedule for a flat.

    A salesperson tries several: 10/20/70 against 30/0/70, twelve months
    against six. Each of those is a record here, so the conversation can be
    revisited rather than recomputed from memory.

    Exactly one of them per lead is the real thing -- ``is_schedule`` -- and
    that is the one invoicing will read. Marking a second clears the first, so
    there can never be two answers to "what is this buyer actually paying".
    """

    _name = 'vertikali.payment.calc'
    _description = "Payment Calculation"
    _order = 'is_schedule desc, create_date desc, id desc'

    name = fields.Char(compute='_compute_name', store=True)
    lead_id = fields.Many2one(
        'crm.lead', string="ლიდი", index=True, ondelete='cascade')
    # No domain here. Which products count as property is the host database's
    # business, and narrowing it in the model would make this module refuse to
    # install where that field does not exist. vertikali_crm_config sets the
    # domain on the view.
    unit_id = fields.Many2one(
        'product.template', string="უძრავი ქონება", required=True, index=True)
    # The contract is written in dollars, so the calculation is too. Flat
    # prices are stored in the company currency, which is GEL on this
    # database, and are converted on the way in at the rate below.
    currency_id = fields.Many2one(
        'res.currency', string="ვალუტა", required=True,
        default=lambda self: self.env.ref('base.USD'))

    is_schedule = fields.Boolean(
        string="რეალური გრაფიკი", copy=False, index=True,
        help="The schedule the buyer actually pays to. One per lead.")

    kind = fields.Selection(
        selection=[('standard', "სტანდარტული"),
                   ('custom', "არასტანდარტული")],
        string="ტიპი", required=True, default='standard')
    plan_id = fields.Many2one(
        'vertikali.payment.plan', string="გრაფიკის ტიპი")
    periodicity = fields.Selection(
        selection=[('month', "თვეში ერთხელ"),
                   ('quarter', "კვარტალში ერთხელ")],
        string="გადახდის პერიოდულობა", required=True, default='month')

    # Every share is shown beside what it comes to in money: a percentage on
    # its own is not something a buyer can be quoted.
    first_pct = fields.Float(string="პირველადი %", digits=(5, 2))
    mid_pct = fields.Float(string="განვადების %", digits=(5, 2))
    last_pct = fields.Float(string="ბოლო %", digits=(5, 2))

    # Signed: minus takes off, plus adds on. Quoted either as a percentage or
    # as a flat sum, against either the metre or the whole flat, because the
    # team uses all four and none of them is a rewording of another.
    adjust_kind = fields.Selection(
        selection=ADJUST_KIND, string="ფასდაკლების ტიპი",
        required=True, default='pct')
    adjust_base = fields.Selection(
        selection=ADJUST_BASE, string="ფასდაკლების სახე",
        required=True, default='sqm')
    adjust_value = fields.Float(string="ფასდაკლება", digits=(12, 2))
    adjust_amount = fields.Monetary(
        string="ფასდაკლების თანხა", compute='_compute_final', store=True)

    # Short labels: these four sit two to a row, and the long form ran into
    # the figure beside it.
    base_price = fields.Monetary(string="საწყისი ფასი")
    base_sqm = fields.Monetary(string="საწყისი კვ.მ")
    final_price = fields.Monetary(
        string="საბოლოო ფასი", compute='_compute_final', store=True)
    final_sqm = fields.Monetary(
        string="საბოლოო კვ.მ", compute='_compute_final', store=True)

    # Short labels: the block is already called "თარიღები", so repeating the
    # word four times only makes each label wrap onto a second line.
    first_date = fields.Date(
        string="პირველადი შენატანი", default=fields.Date.context_today)
    start_date = fields.Date(string="განვადების დაწყება")
    end_date = fields.Date(string="განვადების დასრულება")
    last_date = fields.Date(string="ბოლო შენატანი")

    first_amount = fields.Monetary(
        string="პირველადი თანხა", compute='_compute_final', store=True)
    mid_amount = fields.Monetary(
        string="განვადების თანხა", compute='_compute_final', store=True)
    last_amount = fields.Monetary(
        string="ბოლო თანხა", compute='_compute_final', store=True)

    line_ids = fields.One2many(
        'vertikali.payment.calc.line', 'calc_id', string="გრაფიკი")
    line_count = fields.Integer(compute='_compute_line_count')

    @api.depends('unit_id', 'plan_id', 'kind', 'is_schedule')
    def _compute_name(self):
        for calc in self:
            parts = [calc.unit_id.default_code or calc.unit_id.name or '?']
            if calc.plan_id:
                parts.append(calc.plan_id.name)
            elif calc.kind == 'custom':
                parts.append(_("არასტანდარტული"))
            calc.name = ' · '.join(p for p in parts if p)

    @api.depends('base_price', 'base_sqm', 'adjust_kind', 'adjust_base',
                 'adjust_value', 'first_pct', 'mid_pct', 'last_pct', 'unit_id')
    def _compute_final(self):
        for calc in self:
            price, sqm = apply_adjustment(
                calc.base_price, calc.base_sqm, calc._vk_unit_area(),
                calc.adjust_kind, calc.adjust_base, calc.adjust_value)
            calc.final_price = price
            calc.final_sqm = sqm
            calc.adjust_amount = price - (calc.base_price or 0.0)
            calc.first_amount = calc.final_price * (calc.first_pct or 0.0) / 100.0
            calc.mid_amount = calc.final_price * (calc.mid_pct or 0.0) / 100.0
            calc.last_amount = calc.final_price * (calc.last_pct or 0.0) / 100.0

    @api.depends('line_ids')
    def _compute_line_count(self):
        for calc in self:
            calc.line_count = len(calc.line_ids)

    def _vk_unit_area(self):
        """The flat's area, where the host database records one.

        Read defensively so this module installs on a database with no estate
        module at all: without an area the calculation still works, it simply
        cannot express a discount per square metre as a total.
        """
        self.ensure_one()
        return getattr(self.unit_id, UNIT_AREA_FIELD, 0.0) or 0.0

    @api.model
    def _vk_usd_rate(self):
        """Lari to the dollar. One place, so nothing drifts."""
        params = self.env['ir.config_parameter'].sudo()
        raw = params.get_param(NBG_PARAM) or params.get_param(NBG_LEGACY_PARAM)
        try:
            rate = float(raw)
        except (TypeError, ValueError):
            rate = 0.0
        return rate or NBG_DEFAULT

    @api.model
    def _vk_to_usd(self, amount):
        """Company currency to dollars.

        A database whose company already keeps its prices in dollars has
        nothing to convert, and dividing by the lari rate there would quote
        every flat at a third of its price.
        """
        amount = amount or 0.0
        usd = self.env.ref('base.USD', raise_if_not_found=False)
        if usd and self.env.company.currency_id == usd:
            return amount
        return amount / self._vk_usd_rate()

    @api.onchange('unit_id')
    def _onchange_unit(self):
        for calc in self:
            unit = calc.unit_id
            calc.base_price = self._vk_to_usd(unit.list_price)
            # Where the host records no metre price, derive one from the area
            # if there is one, and leave it at nought if there is not.
            sqm = getattr(unit, UNIT_SQM_PRICE_FIELD, 0.0) or 0.0
            if not sqm:
                area = calc._vk_unit_area()
                sqm = unit.list_price / area if area else 0.0
            calc.base_sqm = self._vk_to_usd(sqm)

    @api.model
    def _default_plan(self):
        """The first type in the team's own order."""
        return self.env['vertikali.payment.plan'].search([], limit=1)

    @api.model
    def default_get(self, fields_list):
        """Open on the first type, with its terms already filled in.

        Standard is the default kind, so an untouched form otherwise shows an
        empty type box and three shares sitting at nought -- a gap where the
        answer should be, and nothing to press გამოთვლა on.
        """
        vals = super().default_get(fields_list)
        plan = self._default_plan()
        if not plan or vals.get('kind', 'standard') != 'standard':
            return vals
        for name, value in (('plan_id', plan.id),
                            ('first_pct', plan.first_pct),
                            ('mid_pct', plan.mid_pct),
                            ('last_pct', plan.last_pct),
                            ('adjust_kind', plan.adjust_kind),
                            ('adjust_base', plan.adjust_base),
                            ('adjust_value', plan.adjust_value)):
            if name in fields_list:
                vals.setdefault(name, value)
        return vals

    @api.onchange('kind')
    def _onchange_kind(self):
        """Standard always has a type; non-standard never carries a stale one."""
        for calc in self:
            if calc.kind == 'standard':
                if not calc.plan_id:
                    calc.plan_id = calc._default_plan()
                calc._onchange_plan()
            else:
                calc.plan_id = False

    @api.onchange('plan_id')
    def _onchange_plan(self):
        """The type carries the terms; picking one fills them in.

        Including the adjustment, which is the whole point of writing it on
        the type: the discount that goes with 10/20/70 is a decision made
        once, up front, not one a salesperson makes per deal.
        """
        for calc in self:
            if calc.plan_id:
                calc.first_pct = calc.plan_id.first_pct
                calc.mid_pct = calc.plan_id.mid_pct
                calc.last_pct = calc.plan_id.last_pct
                calc.adjust_kind = calc.plan_id.adjust_kind
                calc.adjust_base = calc.plan_id.adjust_base
                calc.adjust_value = calc.plan_id.adjust_value

    # ------------------------------------------------------------------
    def _instalment_dates(self):
        """Every instalment date from start to end, inclusive.

        The count comes from the dates rather than being typed: the team sets
        when payments begin and when they end, and how many there are follows.
        """
        self.ensure_one()
        if not (self.start_date and self.end_date):
            return []
        step = relativedelta(months=1 if self.periodicity == 'month' else 3)
        dates, cursor = [], self.start_date
        while cursor <= self.end_date and len(dates) < 600:
            dates.append(cursor)
            cursor += step
        return dates

    def _check_against_plan(self):
        """A standard schedule may be brought forward, never pushed back.

        The type is a floor, not a fixed shape: on 10/20/70 a buyer may put
        15% down, and the balloon shrinks to match. What they may not do is
        put 9% down, or leave more to the end than the type allows.

        Expressed as cumulative shares, which is the only way it stays
        consistent -- checking each of the three against its own minimum would
        make the type unchangeable, since the three always add up to 100.
        """
        self.ensure_one()
        if self.kind != 'standard' or not self.plan_id:
            return
        plan = self.plan_id
        if self.first_pct + 0.01 < plan.first_pct:
            raise ValidationError(_(
                "%(plan)s-ზე პირველადი შენატანი %(min)s%%-ზე ნაკლები ვერ იქნება "
                "(მითითებულია %(got)s%%).",
                plan=plan.name, min=plan.first_pct, got=self.first_pct))
        paid_early = self.first_pct + self.mid_pct
        plan_early = plan.first_pct + plan.mid_pct
        if paid_early + 0.01 < plan_early:
            raise ValidationError(_(
                "%(plan)s-ზე ბოლო შენატანამდე %(min)s%% უნდა იყოს გადახდილი "
                "(მითითებულია %(got)s%%).",
                plan=plan.name, min=plan_early, got=round(paid_early, 2)))
        # The discount is deliberately NOT capped at what the type allows.
        # A salesperson may go below it, and the control over that is meant to
        # be an approval rather than a refusal -- the signatures the team has
        # yet to specify. Until those exist, holding the line here would only
        # send people to the non-standard kind to get around it, which loses
        # the record of what was actually conceded.
        #
        # The floor that stays is on the shares above: the point of 10/20/70
        # is when the money arrives, and that is not the discount's business.
        return

    def _check_dates_order(self):
        """A schedule runs forwards.

        Checked here as well as in the constraint because the calculator on
        the card works on an unsaved record, where constraints never fire.
        """
        self.ensure_one()
        if self.start_date and self.end_date and self.end_date < self.start_date:
            raise ValidationError(_(
                "განვადების დასრულება დაწყებაზე ადრე ვერ იქნება."))
        if self.end_date and self.last_date and self.last_date < self.end_date:
            raise ValidationError(_(
                "ბოლო შენატანი განვადების დასრულებაზე ადრე ვერ იქნება."))

    @api.constrains('start_date', 'end_date', 'last_date')
    def _check_dates(self):
        for calc in self:
            calc._check_dates_order()

    @api.constrains('kind', 'plan_id', 'first_pct', 'mid_pct', 'last_pct',
                    'adjust_kind', 'adjust_base', 'adjust_value')
    def _check_plan_floor(self):
        for calc in self:
            calc._check_against_plan()

    def _schedule_rows(self):
        """The schedule as plain rows, written nowhere.

        Kept separate from action_generate so the informational calculator on
        the unit card can use it too. Working the arithmetic out a second time
        in JavaScript would be a second answer waiting to drift from this one.
        """
        self.ensure_one()
        if not self.unit_id:
            raise UserError(_("აირჩიეთ უძრავი ქონება."))
        # Also checked here, not only by the constraint: the card's calculator
        # works on an unsaved record, where constraints never fire.
        self._check_against_plan()
        self._check_dates_order()
        if self.final_price <= 0:
            raise UserError(_("ფასდაკლების შემდეგ ფასი ნულზე მეტი უნდა იყოს."))
        total = abs(self.first_pct) + abs(self.mid_pct) + abs(self.last_pct)
        if abs(total - 100.0) > 0.01:
            raise UserError(_(
                "პროცენტების ჯამი 100 უნდა იყოს, ახლა %(t)s-ია.",
                t=round(total, 2)))
        dates = self._instalment_dates()
        if self.mid_pct and not dates:
            raise UserError(_(
                "მიუთითეთ განვადების დაწყებისა და დასრულების თარიღი."))

        bdate = self.last_date or self.end_date
        # the balloon's month keeps a single payment: an instalment landing in
        # it is folded away and the remaining ones grow to cover the same
        # share (user rule, mirrors figurebi_installment's schedule)
        if self.last_pct and bdate and dates \
                and (dates[-1].year, dates[-1].month) == (bdate.year, bdate.month):
            dates.pop()
            if self.mid_pct and not dates:
                raise UserError(_(
                    "განვადების ყველა შენატანი ბოლო შენატანის თვეში ხვდება — "
                    "შეცვალეთ თარიღები."))

        price = self.final_price
        remaining = price
        rows, seq = [], 0

        if self.first_pct:
            remaining -= self.first_amount
            seq += 1
            rows.append({
                'sequence': seq, 'name': _("პირველადი შენატანი"),
                'date': self.first_date, 'amount': self.first_amount,
                'remaining': remaining,
            })

        if self.mid_pct and dates:
            # Whole instalments, with the rounding difference put on the last
            # one so the rows always add up to the price exactly.
            mid_total = price * self.mid_pct / 100.0
            rounding = self.currency_id or self.env.company.currency_id
            each = rounding.round(mid_total / len(dates))
            for i, day in enumerate(dates, start=1):
                amount = each if i < len(dates) else mid_total - each * (len(dates) - 1)
                remaining -= amount
                seq += 1
                rows.append({
                    'sequence': seq, 'name': str(i), 'date': day,
                    'amount': amount, 'remaining': remaining,
                })

        if self.last_pct:
            seq += 1
            rows.append({
                'sequence': seq, 'name': _("ბოლო შენატანი"),
                'date': bdate,
                'amount': self.last_amount, 'remaining': 0.0,
            })
        return rows

    def _action_reopen(self):
        """Hand the dialog back, showing what was just worked out.

        A button that returns nothing closes the dialog, which is wrong here:
        the whole point of pressing გამოთვლა is to look at the result and then
        decide whether to keep it, as a calculation or as the schedule.
        """
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': _("განვადების კალკულატორი"),
            'res_model': self._name,
            'res_id': self.id,
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'new',
            'context': dict(self.env.context),
        }

    def action_generate(self):
        """Build the schedule: first payment, the instalments, the balloon."""
        for calc in self:
            rows = calc._schedule_rows()
            calc.line_ids.unlink()
            self.env['vertikali.payment.calc.line'].create(
                [dict(row, calc_id=calc.id) for row in rows])
        return self._action_reopen() if len(self) == 1 else True

    @api.model
    def vk_simulate(self, vals):
        """Work one out without keeping it.

        The calculator opened from the inventory has no deal to belong to, so
        it computes and shows and that is all. Same code as a saved
        calculation, simply not written.
        """
        calc = self.new(vals)
        rows = calc._schedule_rows()
        for row in rows:
            row['date'] = fields.Date.to_string(row['date']) if row['date'] else False
        return {
            'final_price': calc.final_price,
            'final_sqm': calc.final_sqm,
            'adjust_amount': calc.adjust_amount,
            'mid_amount': calc.mid_amount,
            'first_amount': calc.first_amount,
            'last_amount': calc.last_amount,
            'rows': rows,
        }

    def action_set_schedule(self):
        """Make this the schedule the buyer pays to, and only this one."""
        for calc in self:
            if not calc.line_ids:
                raise UserError(_("ჯერ გამოთვალეთ გრაფიკი."))
            if calc.lead_id:
                others = self.search([
                    ('lead_id', '=', calc.lead_id.id),
                    ('id', '!=', calc.id),
                    ('is_schedule', '=', True),
                ])
                others.is_schedule = False
            calc.is_schedule = True
        return self._action_reopen() if len(self) == 1 else True


class VertikaliPaymentCalcLine(models.Model):
    _name = 'vertikali.payment.calc.line'
    _description = "Payment Calculation Line"
    _order = 'calc_id, sequence, id'

    calc_id = fields.Many2one(
        'vertikali.payment.calc', required=True, ondelete='cascade', index=True)
    sequence = fields.Integer(default=10)
    name = fields.Char(string="#", required=True)
    date = fields.Date(string="გადახდის თარიღი")
    amount = fields.Monetary(string="თანხა")
    remaining = fields.Monetary(string="დარჩენილი თანხა")
    currency_id = fields.Many2one(
        related='calc_id.currency_id', readonly=True)

    # Instalments are spaced a month apart from whatever day the first one
    # falls on, so a schedule lands on Saturdays and Sundays without anyone
    # choosing them. Flagged rather than moved: which way to shift a weekend
    # payment is the buyer's agreement to make, not ours to guess.
    vk_weekend = fields.Boolean(
        string="დასვენების დღე", compute='_compute_vk_weekend', store=True)

    @api.depends('date')
    def _compute_vk_weekend(self):
        for line in self:
            line.vk_weekend = bool(line.date) and line.date.weekday() >= 5
