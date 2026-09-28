# -*- coding: utf-8 -*-
"""The price matrix: the team's Excel sheet as a table, built from the units.

Labels are Georgian, field names English.

A matrix is formed from a popup ("მატრიცის ფორმირება", models/wizard.py):
project, building, types, states and the NUMBER OF STAGES. Each type gets
one line with up to MAX_STAGES pairs of (quantity, price per m²); the
table shows as many pairs as the matrix's stage_count, and "+ ეტაპი" on
the form adds one. The last stage's quantity is always total minus the
earlier stages, so the team types the early stages and the rest falls out.

The current price is the price of the current stage. The stage is read
from the sales (the first qty_1 sales at price_1, the next qty_2 at
price_2, ...) unless the team picks one by hand on the line.
"""
from odoo import Command, api, fields, models
from odoo.exceptions import UserError, ValidationError
from markupsafe import Markup

from odoo.tools import float_compare

MAX_STAGES = 10  # columns exist up front and are shown up to stage_count
ROMAN = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X']
# The sheet's layout codes for vertikali's vk_rooms values.
ROOMS_CODE = {'studio': 'S', '1+1': '1B', '2+1': '2B', '3+1': '3B', '4+1': '4B', 'commercial': 'C'}
SOLD_STATE = 'sold'
RESERVED_STATE = 'reserved'      # a priced reservation: off the market, own column (D-53)
SOLD_STATES = (SOLD_STATE, RESERVED_STATE)  # the sheet's "გაყიდული / ფასით დაჯავშნილი"
OFF_STATE = 'notforsale'          # never sold: not a unit of the matrix at all (D-71)


def _before_commit(env, key, items, run):
    """Collect items under key and call run(env, items) once, as superuser,
    just before the transaction commits: the sale or the edit that caused
    it and what it causes are saved together or not at all."""
    data = env.cr.precommit.data
    pending = data.get(key)
    if pending is None:
        pending = data[key] = []
        su = env(su=True)

        def _run():
            run(su, data.pop(key, []))
            su.flush_all()
        env.cr.precommit.add(_run)
    pending.extend(items)


def _money(value):
    return '$%s' % '{:,.2f}'.format(value or 0.0)


def _n(count):
    """A stage count clamped to 1..MAX_STAGES."""
    return max(1, min(count or 3, MAX_STAGES))


def stage_of(stages, sold, manual=None):
    """(stage, price) for [(qty, price), ...]: the stage picked by hand,
    else the one the sales have reached -- the first qty_1 sales at stage I,
    the next qty_2 at stage II, ... A stage with no price inherits the last
    priced one before it; past every stage the last stage applies. Shared by
    the line's compute and the formation popup's preview."""
    n = len(stages)
    if manual:
        stage = min(int(manual), n)
    else:
        before, stage = 0, n
        for i, (qty, _p) in enumerate(stages, 1):
            if (sold or 0) < before + (qty or 0):
                stage = i
                break
            before += qty or 0
    price = 0.0
    for i, (_q, p) in enumerate(stages, 1):
        price = p or price
        if i == stage:
            break
    return stage, price


class VertikaliPriceMatrixState(models.Model):
    """The four unit states as records, so the popup can offer them in one
    compact multi-select (tags) instead of four checkboxes."""
    _name = 'vertikali.price.matrix.state'
    _description = 'ბინის სტატუსი (მატრიცის ფილტრი)'
    _order = 'sequence, id'

    name = fields.Char(string='სტატუსი', required=True)
    code = fields.Char(string='კოდი', required=True, help="product.template.vk_state-ის მნიშვნელობა.")
    sequence = fields.Integer(default=10)

    _code_uniq = models.Constraint('unique(code)', "ასეთი სტატუსი უკვე არსებობს.")


class VertikaliPriceMatrixLayout(models.Model):
    """The layouts the popup filters on (Studio, 1+1, ...), a record per
    product.template.vk_rooms value, so the filter is tags like the states."""
    _name = 'vertikali.price.matrix.layout'
    _description = 'ფასების მატრიცა - ოთახიანობა (ფილტრი)'
    _order = 'sequence, id'

    name = fields.Char(string='ოთახიანობა', required=True)
    code = fields.Char(string='კოდი', required=True, help="product.template.vk_rooms-ის მნიშვნელობა.")
    sequence = fields.Integer(default=10)


class VertikaliPriceMatrixType(models.Model):
    """The sheet's ტიპი column as a list of its own: 1-WS-1B, 1-BS-1B, ...
    Filled from the sheet on import and from formation; editable in
    Configuration. The popup's ტიპი dropdown reads this list."""
    _name = 'vertikali.price.matrix.type'
    _description = 'ბინის ტიპი (მატრიცა)'
    _order = 'sequence, code, id'
    _rec_name = 'code'

    code = fields.Char(string='ტიპი', required=True, index=True)
    sequence = fields.Integer(string='რიგითობა', default=10)
    active = fields.Boolean(string='აქტიური', default=True)
    block = fields.Char(string='კორპუსი', compute='_compute_code_parts', store=True, readonly=False)
    view_class = fields.Char(string='ხედის კლასი', compute='_compute_code_parts', store=True, readonly=False)
    layout = fields.Char(string='ოთახიანობა', compute='_compute_code_parts', store=True, readonly=False)
    note = fields.Char(string='შენიშვნა')

    _code_uniq = models.Constraint('unique(code)', "ასეთი ტიპი უკვე არსებობს.")

    @api.depends('code')
    def _compute_code_parts(self):
        for rec in self:
            parts = [p.strip() for p in (rec.code or '').split('-')]
            if len(parts) == 3:
                rec.block, rec.view_class, rec.layout = parts
            elif not rec.code:
                rec.block = rec.view_class = rec.layout = False

    @api.model
    def _get_or_create(self, code):
        code = (code or '').strip()
        if not code:
            return self.browse()
        rec = self.with_context(active_test=False).search([('code', '=', code)], limit=1)
        return rec or self.create({'code': code})




class VertikaliPriceMatrixHistory(models.Model):
    """One row per value that changed: which type, which cell, what it was,
    what it became, who did it, when and why. Written by the line's write()
    and by the formation popup; read from the matrix's ისტორია button."""
    _name = 'vertikali.price.matrix.history'
    _description = 'ფასების მატრიცის ისტორია'
    _order = 'create_date desc, id desc'

    matrix_id = fields.Many2one('vertikali.price.matrix', string='მატრიცა', required=True,
                                ondelete='cascade', index=True)
    line_id = fields.Many2one('vertikali.price.matrix.line', string='ხაზი', ondelete='set null')
    code = fields.Char(string='ტიპი', index=True)
    field = fields.Char(string='რა შეიცვალა', required=True)
    old_value = fields.Char(string='იყო')
    new_value = fields.Char(string='გახდა')
    user_id = fields.Many2one('res.users', string='ვინ', required=True, default=lambda self: self.env.user)
    reason = fields.Char(string='მიზეზი')
    date = fields.Datetime(string='როდის', default=fields.Datetime.now, required=True)


class VertikaliPriceMatrix(models.Model):
    _name = 'vertikali.price.matrix'
    _inherit = ['mail.thread']
    _description = 'ფასების მატრიცა'
    _order = 'name'

    name = fields.Char(string='დასახელება', required=True)
    active = fields.Boolean(string='აქტიური', default=True)
    currency_id = fields.Many2one(
        'res.currency', string='ვალუტა', required=True,
        default=lambda self: self.env.company.currency_id)
    note = fields.Text(string='შენიშვნა')

    # ---- what the popup wrote: the filter and the shape of the table --------
    project_id = fields.Many2one('vertikali.project', string='პროექტი', index=True, ondelete='set null')
    project = fields.Char(string='პროექტი (ტექსტი)',
                          help="მატრიცისთვის, რომლის ბინები ამ ბაზაზე არ არის.")
    f_building = fields.Char(string='კორპუსი / ბლოკი',
                             help="ერთი ან რამდენიმე კორპუსი მძიმით (A, B). ცარიელი = ყველა.")
    f_type_ids = fields.Many2many('vertikali.price.matrix.type', 'vk_price_matrix_type_rel', 'matrix_id', 'type_id',
                                  string='ტიპები', help="ცარიელი = ყველა ტიპი.")
    f_view_ids = fields.Many2many('vertikali.option', 'vk_price_matrix_view_rel', 'matrix_id', 'option_id',
                                  string='ხედი', domain=[('attribute', '=', 'view')],
                                  help="ცარიელი = ყველა ხედი.")
    f_layout_ids = fields.Many2many('vertikali.price.matrix.layout', 'vk_price_matrix_layout_rel',
                                    'matrix_id', 'layout_id', string='ოთახიანობა',
                                    help="ცარიელი = ყველა ოთახიანობა.")
    f_state_ids = fields.Many2many('vertikali.price.matrix.state', 'vk_price_matrix_state_rel', 'matrix_id', 'state_id',
                                   string='სტატუსი', help="ცარიელი = ყველა სტატუსი.")
    stage_count = fields.Integer(string='ეტაპების რაოდენობა', default=3,
                                 help="რამდენი ეტაპი (რაოდენობა + ფასი) ჩანს ცხრილში; „+ ეტაპი“ ამატებს.")
    # the "+ ეტაპი" switch above the table: how many stage columns to add,
    # so a column pair is one click away and the popup is not needed for it
    add_stage_open = fields.Boolean(string='+ ეტაპი')
    # the matrix drives the list prices of its free units (D-69); off by
    # default, and one matrix per unit
    sync_prices = fields.Boolean(
        string='ფასები ბინებზე', default=False, copy=False,
        help="ჩართული = ტიპის მიმდინარე ფასი მ² თავისუფალ ბინებზე იწერება: ეტაპის ან ფასის "
             "ცვლილებისას ბინის ფასი სხვაობით (სხვაობა × ფართი) იცვლება. გაყიდული და დაჯავშნილი "
             "ბინები თავის ფასზე რჩება. ჩართვის მომენტში ფასები არ იცვლება.")
    unit_count = fields.Integer(string='ბინები ფილტრში', compute='_compute_unit_count')
    last_generated = fields.Datetime(string='ბოლო ფორმირება', readonly=True)
    # who formed it last and why (the popup writes these); every change,
    # cell by cell, is in history_ids
    last_user_id = fields.Many2one('res.users', string='პასუხისმგებელი', readonly=True)
    last_reason = fields.Char(string='მიზეზი', readonly=True)
    history_ids = fields.One2many('vertikali.price.matrix.history', 'matrix_id', string='ისტორია')
    history_count = fields.Integer(string='ცვლილებები', compute='_compute_history_count')

    @api.depends('history_ids')
    def _compute_history_count(self):
        for rec in self:
            rec.history_count = len(rec.history_ids)

    def action_open_history(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': 'ისტორია - %s' % self.name,
            'res_model': 'vertikali.price.matrix.history',
            'view_mode': 'list',
            'domain': [('matrix_id', '=', self.id)],
            'context': {'default_matrix_id': self.id, 'create': False},
        }

    def _log(self, field, old='', new='', code='', line=None, reason=None, user=None):
        """One history row on this matrix."""
        self.ensure_one()
        self.env['vertikali.price.matrix.history'].sudo().create({
            'matrix_id': self.id, 'line_id': line.id if line else False, 'code': code,
            'field': field, 'old_value': str(old) if old not in (None, False) else '',
            'new_value': str(new) if new not in (None, False) else '',
            'reason': reason if reason is not None else self.env.context.get('vk_reason') or '',
            'user_id': (user or self.env.user).id,
        })
    filter_summary = fields.Char(string='ფორმირება', compute='_compute_filter_summary')

    line_ids = fields.One2many('vertikali.price.matrix.line', 'matrix_id', string='ტიპები')
    line_count = fields.Integer(string='ტიპების რაოდენობა', compute='_compute_line_count')

    @api.depends('line_ids')
    def _compute_line_count(self):
        for rec in self:
            rec.line_count = len(rec.line_ids)

    @api.constrains('stage_count')
    def _check_stage_count(self):
        for rec in self:
            if not 1 <= rec.stage_count <= MAX_STAGES:
                raise ValidationError("ეტაპების რაოდენობა 1-დან %d-მდე შეიძლება იყოს." % MAX_STAGES)

    # ------------------------------------------------------------------
    # a new matrix from "New" (D-67)
    # ------------------------------------------------------------------
    @api.onchange('project_id')
    def _onchange_project_new_matrix(self):
        """A brand-new matrix: picking the project lays out its types.

        One line per type found among the project's units, with the total,
        sold and reserved counts; one stage, left at 0 units and 0 per m²
        -- the team types which units go on which stage at what price.
        Only while the matrix is unsaved: a saved matrix is re-formed from
        the ⚙ Actions popup, which keeps what was typed (D-47)."""
        if self._origin.id or not self.project_id:
            return
        if not self.name:
            self.name = self.project_id.name
        groups = {}
        for u in self._units():
            code = self._type_code(u)
            groups[code] = groups.get(code, self.env['product.template']) | u
        cmds = [Command.clear()]
        for seq, code in enumerate(sorted(groups), 1):
            us = groups[code]
            cmds.append(Command.create({
                'code': code, 'sequence': seq * 10, 'auto': True,
                'qty_total': len(us),
                'qty_sold': len(us.filtered(lambda u: u.vk_state == SOLD_STATE)),
                'qty_reserved': len(us.filtered(lambda u: u.vk_state == RESERVED_STATE)),
                'unit_ids': [Command.set(us.ids)],
                'qty_1': 0, 'price_1': 0.0,
            }))
        self.stage_count = 1
        self.line_ids = cmds

    @api.model_create_multi
    def create(self, vals_list):
        """Lines that come in with the matrix keep their stages as given:
        the new-matrix onchange leaves stage I at 0 on purpose, and the
        remainder rule would fill it with the total (D-67). The rule is
        back for every later edit."""
        recs = super(VertikaliPriceMatrix, self.with_context(vk_keep_stages=True)).create(vals_list)
        recs = recs.with_env(self.env)
        for rec in recs.filtered(lambda r: r.project_id and r.line_ids):
            rec.write({'last_generated': fields.Datetime.now(),
                       'last_user_id': self.env.user.id,
                       'last_reason': 'ახალი მატრიცა'})
            rec._log('ახალი მატრიცა', '', '%s | %d ტიპი' % (rec.project_id.name, len(rec.line_ids)),
                     reason='ახალი მატრიცა')
        return recs

    def write(self, vals):
        """A changed stage count re-shapes every line: stages beyond the new
        count are blanked, the new last stage takes the remainder."""
        old = {rec.id: rec.stage_count for rec in self}
        if 'active' in vals and not vals['active'] and any(self.mapped('sync_prices')):
            # an archived matrix writes no prices (D-70); unarchiving does not
            # switch them back on by itself
            vals = dict(vals, sync_prices=False)
        turned_on =self.filtered(lambda r: not r.sync_prices) if vals.get('sync_prices') else self.browse()
        res = super().write(vals)
        for rec in turned_on:
            rec._vk_set_price_base()
        if 'sync_prices' in vals and not vals['sync_prices']:
            for rec in self:
                rec._log('ფასები ბინებზე', 'ჩართული', 'გამორთული')
        if 'stage_count' in vals:
            for rec in self:
                n_old, n_new = old[rec.id], rec.stage_count
                clear = {}
                if n_new > n_old:
                    clear['qty_%d' % n_old] = 0          # the old remainder moves on
                for i in range(n_new + 1, MAX_STAGES + 1):
                    clear['qty_%d' % i] = 0
                    clear['price_%d' % i] = 0.0
                if clear and rec.line_ids:
                    rec.line_ids.write(clear)
                rec.line_ids._fill_last_stage()
        return res

    # ------------------------------------------------------------------
    # units that join or leave the project (D-71)
    # ------------------------------------------------------------------
    def _vk_refresh_units(self, changed=None):
        """Keep the lines built from units in step with the project.

        A unit that joins a type (a new flat, a flat back on sale, a type
        corrected) goes on the stage the type is on now and, with the prices
        on, takes that stage's price per m² × its area. A unit that leaves
        (not for sale, deleted, moved to another type) comes off the last
        stage, then the ones before it. Lines typed by hand (no units, never
        formed) are left alone, and so is a type the matrix does not have:
        it is announced in the chatter, and the ⚙ Actions popup adds it."""
        Unit = self.env['product.template']
        for m in self.filtered(lambda r: r.active and r.project_id):
            groups = {}
            for u in m._units(states=False):
                groups.setdefault(m._type_code(u), []).append(u.id)
            for line in m.line_ids.filtered(lambda l: l.auto or l.unit_ids):
                target = Unit.browse(groups.get(line.code, []))
                if target == line.unit_ids and line.qty_total == len(target):
                    continue
                # a line that never had its units (formed before they were
                # kept, or saved without them) is only filled in: its units
                # are not new, its total already counts them
                first_fill = not line.unit_ids
                added = Unit.browse() if first_fill else target - line.unit_ids
                n, cur = _n(line.stage_count), line.stage_current or 1
                old_total = line.qty_total or 0
                grow = len(target) - old_total
                vals = {'unit_ids': [Command.set(target.ids)], 'qty_total': len(target)}
                if grow > 0 and cur < n:
                    vals['qty_%d' % cur] = (line['qty_%d' % cur] or 0) + grow
                line.with_context(vk_trim=True, vk_reason='ბინები პროექტიდან').write(vals)
                priced = line._vk_price_new_units(added)
                if first_fill and not grow:
                    continue
                m.message_post(
                    body=Markup('<p><b>%s</b>: სულ %d → %d%s%s</p>') % (
                        line.code, old_total, len(target),
                        ' (+%d ბინა %s ეტაპზე)' % (grow, ROMAN[cur - 1]) if grow > 0 else '',
                        ', %d ბინას ფასი %s / მ²' % (priced, _money(line.price_current)) if priced else ''),
                    message_type='notification', subtype_xmlid='mail.mt_note')
            if changed:
                known = set(m.line_ids.mapped('code'))
                mine = changed & Unit.browse([i for ids in groups.values() for i in ids])
                loose = sorted({m._type_code(u) for u in mine} - known)
                if loose:
                    m.message_post(
                        body=Markup('<p>ახალი ტიპი, რომელიც მატრიცაში არ არის: <b>%s</b>. '
                                    'დასამატებლად ⚙ Actions → „ცხრილის აწყობა ბინებიდან“.</p>') % ', '.join(loose),
                        message_type='notification', subtype_xmlid='mail.mt_note')

    @api.constrains('sync_prices')
    def _check_sync_prices(self):
        """A unit takes its price from one matrix only: two would each add
        their difference, or overwrite each other."""
        for rec in self.filtered('sync_prices'):
            others = self.search([('sync_prices', '=', True), ('id', '!=', rec.id)])
            clash = rec.line_ids.unit_ids & others.line_ids.unit_ids
            if clash:
                names = others.filtered(lambda o: o.line_ids.unit_ids & clash).mapped('name')
                raise ValidationError(
                    "%d ბინა უკვე იღებს ფასს სხვა მატრიციდან (%s). ერთ ბინას ფასს ერთი მატრიცა "
                    "უწერს - ჯერ იქ გამორთე „ფასები ბინებზე“." % (len(clash), ', '.join(names)))

    def _vk_set_price_base(self):
        """Switching the prices on changes no price: every unit records its
        type's current price as the base the next change is measured from.
        Reserved units too, so one whose reservation is cancelled later
        catches up with the stages it missed."""
        self.ensure_one()
        for line in self.line_ids.filtered('price_current'):
            line.unit_ids.sudo().write({'vk_pm_price_base': line.price_current})
        self._log('ფასები ბინებზე', 'გამორთული', 'ჩართული')

    # ------------------------------------------------------------------
    # stage columns from the table itself ("+ ეტაპი")
    # ------------------------------------------------------------------
    def _set_stage_count(self, new):
        """Change the number of stage columns and write it to history. The
        re-shaping of the lines is write()'s, unchanged."""
        self.ensure_one()
        old = self.stage_count
        # vk_trim: re-shaping the columns must not trip over a line whose
        # stages were already out of step with its total (D-51 refuses that
        # to the team's hand, not to a structural change)
        self.with_context(vk_trim=True).write({'stage_count': new, 'add_stage_open': False})
        self._log('ეტაპების რაოდენობა', old, new)

    def action_add_stages(self):
        """The plus button: one more stage column, one click (D-49).

        Adding a stage moves nothing by itself (D-47). Every type keeps the
        units it has on its stages and the new columns carry its own last
        price, so no type changes hands or price. The team then types the
        quantity and the price of the types the new stage is really for --
        the last stage fills itself, so lowering stage III by six units
        puts those six on stage IV.
        """
        self.ensure_one()
        n, n_old = 1, self.stage_count
        if n_old + n > MAX_STAGES:
            raise UserError("მატრიცას მაქსიმუმ %d ეტაპი შეიძლება ჰქონდეს - ახლა %d-ია."
                            % (MAX_STAGES, n_old))
        # what every type had before the columns were added: the units on
        # the old last stage and the price it carries
        lines = self.line_ids
        before = {line.id: (line['qty_%d' % n_old] or 0, line._last_price()) for line in lines}
        self._set_stage_count(n_old + n)
        for line in lines.with_context(vk_trim=True):
            qty, price = before[line.id]
            vals = {'qty_%d' % n_old: qty}
            if price:
                for i in range(n_old + 1, n_old + n + 1):
                    vals['price_%d' % i] = price
            line.write(vals)
        return True

    def action_remove_last_stage(self):
        """Take the last stage column away: its quantity goes back to the
        stage before it. A type that is pinned to that stage by hand stops
        it -- the pin would point at a stage that no longer exists."""
        self.ensure_one()
        if self.stage_count <= 1:
            raise UserError("ერთი ეტაპი მაინც უნდა დარჩეს.")
        gone = str(self.stage_count)
        pinned = self.line_ids.filtered(lambda l: l.stage_manual == gone)
        if pinned:
            codes = pinned.mapped('code')
            raise UserError("%s ეტაპი ხელით არის არჩეული %d ტიპზე (%s%s) - ჯერ იქ „ეტაპის არჩევა“ შეცვალე."
                            % (ROMAN[self.stage_count - 1], len(codes), ', '.join(codes[:8]),
                               '…' if len(codes) > 8 else ''))
        self._set_stage_count(self.stage_count - 1)
        return True

    # ------------------------------------------------------------------
    # the filter
    # ------------------------------------------------------------------
    def _state_filter(self):
        self.ensure_one()
        return self.f_state_ids.mapped('code')

    def _units(self, states=True):
        """The project's units narrowed by the matrix's filter. A unit that
        is not for sale is never one of them: it would hold a place on a
        stage it can never be sold from (D-71). states=False leaves the
        status filter out -- the live refresh keeps sold units in, they are
        what the counts measure."""
        self.ensure_one()
        if not self.project_id:
            return self.env['product.template']
        units = self.project_id._units().filtered(lambda u: u.vk_state != OFF_STATE)
        if self.f_building:
            wanted = {b.strip() for b in self.f_building.split(',') if b.strip()}
            units = units.filtered(lambda u: (u.vk_building or '') in wanted)
        if self.f_view_ids:
            views = set(self.f_view_ids.ids)
            units = units.filtered(lambda u: u.vk_view_id.id in views)
        if self.f_layout_ids:
            rooms = set(self.f_layout_ids.mapped('code'))
            units = units.filtered(lambda u: u.vk_rooms in rooms)
        if self.f_type_ids:
            codes = set(self.f_type_ids.mapped('code'))
            units = units.filtered(lambda u: self._type_code(u) in codes)
        wanted = self._state_filter() if states else []
        if wanted:
            units = units.filtered(lambda u: u.vk_state in wanted)
        return units

    @api.depends('project_id', 'f_building', 'f_view_ids', 'f_layout_ids', 'f_type_ids', 'f_state_ids')
    def _compute_unit_count(self):
        for rec in self:
            rec.unit_count = len(rec._units()) if rec.project_id else 0

    @api.depends('project_id', 'project', 'f_building', 'f_view_ids', 'f_layout_ids', 'f_type_ids',
                 'stage_count', 'f_state_ids')
    def _compute_filter_summary(self):
        for rec in self:
            parts = [rec.project_id.name or rec.project or '-']
            if rec.f_building:
                parts.append('კორპუსი ' + rec.f_building)
            if rec.f_view_ids:
                parts.append(', '.join(rec.f_view_ids.mapped('name')))
            if rec.f_layout_ids:
                parts.append(', '.join(rec.f_layout_ids.mapped('name')))
            if rec.f_type_ids:
                parts.append('%d ტიპი' % len(rec.f_type_ids))
            if rec.f_state_ids:
                parts.append(', '.join(rec.f_state_ids.mapped('name')))
            parts.append('%d ეტაპი' % (rec.stage_count or 0))
            rec.filter_summary = ' · '.join(parts)

    @staticmethod
    def _type_code(unit):
        """The sheet's type code for a unit: კორპუსი-ხედის კლასი-ოთახიანობა."""
        view = unit.vk_view_id
        view_code = (view.vk_matrix_code or view.name or '').strip() if view else ''
        return '-'.join(p for p in (
            (unit.vk_building or '').strip(),
            view_code,
            ROOMS_CODE.get(unit.vk_rooms, unit.vk_rooms or ''),
        ) if p) or '?'

    def action_generate(self):
        """Form the table.

        With a project: one line per type found among the filtered units,
        total and sold counts from the units. Without a project (a sheet
        whose units are not here): one line per chosen type, totals typed
        by hand. Existing lines keep their stage quantities and prices and
        only get new counts; new lines start with stage 1 = every unit at
        the units' average price per m². A line whose type is not in this
        selection is left alone -- forming a few types must never take the
        other types out of the table (D-47); a row that is really finished
        is deleted by hand in the table.
        """
        Line = self.env['vertikali.price.matrix.line'].with_context(vk_trim=True)
        for rec in self.with_context(vk_trim=True):
            by_code = {l.code: l for l in rec.line_ids}
            if rec.project_id:
                units = rec._units()
                if not units:
                    raise UserError("ამ ფილტრით ბინა არ მოიძებნა.")
                groups = {}
                for u in units:
                    code = rec._type_code(u)
                    groups[code] = groups.get(code, self.env['product.template']) | u
            else:
                if not rec.f_type_ids:
                    raise UserError("აირჩიე პროექტი, ან ტიპები, რომლებზეც მატრიცა უნდა აიწყოს.")
                groups = {t.code: self.env['product.template'] for t in rec.f_type_ids}
            seq = 10
            for code in sorted(groups):
                us = groups[code]
                vals = {'auto': True, 'sequence': seq}
                if us:
                    vals.update(qty_total=len(us),
                                qty_sold=len(us.filtered(lambda u: u.vk_state == SOLD_STATE)),
                                qty_reserved=len(us.filtered(lambda u: u.vk_state == RESERVED_STATE)),
                                unit_ids=[(6, 0, us.ids)])
                line = by_code.get(code)
                if line:
                    line.write(vals)
                else:
                    priced = us.filtered('vk_price_sqm')
                    avg = round(sum(priced.mapped('vk_price_sqm')) / len(priced)) if priced else 0.0
                    Line.create(dict(vals, matrix_id=rec.id, code=code,
                                     qty_1=len(us), price_1=avg))
                seq += 10
            # no unlink here: a type outside this selection stays in the table
            rec.line_ids._fill_last_stage()
            rec.last_generated = fields.Datetime.now()
        return True


def _stage_onchanges():
    """One onchange per stage column, declared in a loop like the fields.

    The line has to know WHICH stage was typed. The last stage takes its
    units from the stage before it (D-52), so typing 6 on the new column
    moves six units off the old last one; any earlier stage leaves the
    remainder to the last, the rule the table always had.
    """
    out = {}
    for idx in range(1, MAX_STAGES + 1):
        def _onchange(self, idx=idx):
            n = _n(self.stage_count)
            if idx > n:
                return
            if idx == n and n > 1:
                self._vk_take_from_previous(n)
            else:
                self['qty_%d' % n] = self._last_stage_qty()
        name = '_onchange_qty_%d' % idx
        _onchange.__name__ = name
        out[name] = api.onchange('qty_%d' % idx)(_onchange)
    return out


def _stage_fields():
    """qty_1 .. qty_N and price_1 .. price_N, declared in a loop so the
    number of stages is one constant."""
    out = {}
    for i in range(1, MAX_STAGES + 1):
        out['qty_%d' % i] = fields.Integer(string='%s ეტაპი - რაოდენობა' % ROMAN[i - 1])
        out['price_%d' % i] = fields.Monetary(string='%s ეტაპი - ფასი მ²' % ROMAN[i - 1],
                                              currency_field='currency_id')
    return out


class VertikaliPriceMatrixLine(models.Model):
    _name = 'vertikali.price.matrix.line'
    _description = 'ფასების მატრიცის ხაზი'
    _order = 'matrix_id, sequence, code, id'
    _rec_name = 'code'

    matrix_id = fields.Many2one('vertikali.price.matrix', string='მატრიცა', required=True,
                                ondelete='cascade', index=True)
    currency_id = fields.Many2one(related='matrix_id.currency_id')
    stage_count = fields.Integer(related='matrix_id.stage_count')
    sequence = fields.Integer(string='რიგითობა', default=10)

    code = fields.Char(string='ტიპი', required=True, index=True,
                       help="კორპუსი – ხედის კლასი – ოთახიანობა, მაგ. 1-WS-1B.")
    type_id = fields.Many2one('vertikali.price.matrix.type', string='ტიპი (სია)', index=True,
                              ondelete='set null')
    qty_total = fields.Integer(string='სულ ბინა')
    # sold and priced-reservation units are counted apart but weigh the same
    # on the stages: both are off the market (D-53)
    # live from the units' status when the line has units (D-68): a sale or a
    # reservation moves the stage at once; typed by hand when it has none
    qty_sold = fields.Integer(string='გაყიდული', compute='_compute_qty_sold', store=True, readonly=False)
    qty_reserved = fields.Integer(string='დაჯავშნილი', compute='_compute_qty_sold', store=True, readonly=False,
                                  help="ფასიანი ჯავშნის ბინები. გაყიდულებთან ერთად ითვლება - "
                                       "ეტაპსაც, „დარჩა“-საც და „შემდეგ ეტაპამდე“-საც.")
    qty_taken = fields.Integer(string='გაყიდული + ჯავშანი', compute='_compute_qty_left', store=True,
                               help="ბაზრიდან მოხსნილი ბინები: გაყიდული + ფასიანი ჯავშანი.")
    qty_left = fields.Integer(string='დარჩენილი', compute='_compute_qty_left', store=True)
    # the stage is read from the most units ever taken, so it never steps
    # back when a sale or a reservation is cancelled (D-71)
    qty_taken_peak = fields.Integer(string='მაქს. გაყიდული + ჯავშანი', compute='_compute_qty_taken_peak',
                                    store=True,
                                    help="ყველაზე მეტი ბინა, რაც ტიპს ოდესმე ჰქონდა გაყიდული და დაჯავშნილი. "
                                         "ეტაპი ამით ითვლება - გაუქმებული გაყიდვა ან ჯავშანი ტიპს წინა, "
                                         "იაფ ეტაპზე აღარ აბრუნებს.")

    # Which stage the type is on. 'auto' reads it from the sales; a number
    # pins it by hand -- the team decides when a type moves on, no code.
    stage_manual = fields.Selection(
        [('auto', 'ავტომატური')] + [(str(i), '%s ეტაპი' % ROMAN[i - 1]) for i in range(1, MAX_STAGES + 1)],
        string='ეტაპი', default='auto', required=True,
        help="ავტომატური = გაყიდვების მიხედვით (პირველი N გაყიდვა I ეტაპია, შემდეგი N - II …). "
             "ეტაპის არჩევა მას ხელით აყენებს.")
    stage_current = fields.Integer(string='მოქმედი ეტაპი', compute='_compute_price_current', store=True)
    stage_label = fields.Char(string='მოქმედი ეტაპი', compute='_compute_price_current', store=True)
    price_current = fields.Monetary(string='მიმდინარე ფასი მ²', currency_field='currency_id',
                                    compute='_compute_price_current', store=True,
                                    help="მოქმედი ეტაპის ფასი.")
    qty_to_next = fields.Integer(string='შემდეგ ეტაპამდე', compute='_compute_price_current', store=True,
                                 help="რამდენი ბინა უნდა გაიყიდოს კიდევ, რომ ტიპი შემდეგ ეტაპზე გადავიდეს "
                                      "და ფასი აიწიოს. 0 = ბოლო ეტაპია ან ხელით არის დაფიქსირებული.")

    locals().update(_stage_fields())

    block = fields.Char(string='კორპუსი', compute='_compute_code_parts', store=True, readonly=False)
    view_class = fields.Char(string='ხედის კლასი', compute='_compute_code_parts', store=True, readonly=False)
    layout = fields.Char(string='ოთახიანობა', compute='_compute_code_parts', store=True, readonly=False)

    unit_ids = fields.Many2many('product.template', 'vk_price_matrix_line_unit_rel', 'line_id', 'unit_id',
                                string='ბინები')
    unit_count = fields.Integer(string='ბინები', compute='_compute_unit_count')
    auto = fields.Boolean(string='ფორმირებიდან', default=False,
                          help="ჩართული = ხაზი ფორმირებამ შექმნა და ის აახლებს.")

    _code_uniq = models.Constraint(
        'unique(matrix_id, code)',
        "ამ ტიპის კოდი მატრიცაში უკვე არსებობს.",
    )

    # ------------------------------------------------------------------
    # stages
    # ------------------------------------------------------------------
    def _stages(self):
        """[(qty, price), ...] for the matrix's stage count."""
        self.ensure_one()
        return [(self['qty_%d' % i], self['price_%d' % i]) for i in range(1, _n(self.stage_count) + 1)]

    def _last_price(self):
        """The last price the type actually carries: the price of its last
        priced stage. An added stage that is not for this type gets this
        price, so the type stays where it is."""
        self.ensure_one()
        price = 0.0
        for i in range(1, _n(self.stage_count) + 1):
            price = self['price_%d' % i] or price
        return price

    def _last_stage_qty(self):
        """What the last stage must hold: the total minus the earlier stages."""
        self.ensure_one()
        earlier = sum((self['qty_%d' % i] or 0) for i in range(1, _n(self.stage_count)))
        return max((self.qty_total or 0) - earlier, 0)

    def _fill_last_stage(self):
        """Keep the stages consistent with the total: the last stage takes
        the remainder and stages beyond the count are blanked.

        A number typed by hand is never cut down quietly (D-51): if the
        stages add up to more than the type has, the value stays as typed
        and `_check_quantities` refuses the save. Only formation trims
        (context `vk_trim`), where a type that shrank -- a status filter,
        fewer units than the table said -- must lose stages from the end
        instead of blocking the whole run.
        """
        for rec in self:
            n = _n(rec.stage_count)
            vals = {}
            earlier = [(rec['qty_%d' % i] or 0) for i in range(1, n)]
            if rec.env.context.get('vk_trim'):
                left = rec.qty_total or 0
                for i, q in enumerate(earlier, 1):
                    if q > left:
                        vals['qty_%d' % i] = q = left
                    left -= q
                vals['qty_%d' % n] = left
            elif ('qty_%d' % n) in (rec.env.context.get('vk_typed') or ()):
                pass  # the last stage itself was typed (D-52): keep it as it
                      # is and let _check_quantities judge the sum
            else:
                vals['qty_%d' % n] = max((rec.qty_total or 0) - sum(earlier), 0)
            for i in range(n + 1, MAX_STAGES + 1):
                if rec['qty_%d' % i]:
                    vals['qty_%d' % i] = 0
            vals = {k: v for k, v in vals.items() if rec[k] != v}
            if vals:
                super(VertikaliPriceMatrixLine, rec).write(vals)

    @api.onchange('qty_total')
    def _onchange_qty_total(self):
        self['qty_%d' % _n(self.stage_count)] = self._last_stage_qty()

    def _vk_take_from_previous(self, n):
        """The last stage was typed: the stage before it hands the units
        over (D-52). Everything else stays as it is, so moving six units
        from III to IV is one number, and taking them from another stage
        instead is the team's own edit."""
        self.ensure_one()
        others = sum((self['qty_%d' % i] or 0) for i in range(1, n - 1))
        rest = (self.qty_total or 0) - others - (self['qty_%d' % n] or 0)
        self['qty_%d' % (n - 1)] = max(rest, 0)

    locals().update(_stage_onchanges())

    @api.model_create_multi
    def create(self, vals_list):
        Type = self.env['vertikali.price.matrix.type']
        for vals in vals_list:
            if vals.get('code') and not vals.get('type_id'):
                vals['type_id'] = Type._get_or_create(vals['code']).id
        lines = super().create(vals_list)
        if not self.env.context.get('vk_keep_stages'):
            lines._fill_last_stage()
        return lines

    LOGGED = ('qty_total', 'qty_sold', 'qty_reserved', 'stage_manual') + tuple('qty_%d' % i for i in range(1, MAX_STAGES + 1)) \
             + tuple('price_%d' % i for i in range(1, MAX_STAGES + 1))

    def write(self, vals):
        if 'code' in vals and 'type_id' not in vals:
            vals = dict(vals, type_id=self.env['vertikali.price.matrix.type']._get_or_create(vals['code']).id)
        watched = [k for k in vals if k in self.LOGGED]
        before = {rec.id: {k: rec[k] for k in watched} for rec in self} if watched else {}
        res = super().write(vals)
        typed = tuple(k for k in vals if k.startswith('qty_'))
        if 'qty_total' in vals or typed:
            # which quantities came from this write: a last stage among them
            # is kept as typed instead of being derived again (D-52)
            self.with_context(vk_typed=typed)._fill_last_stage()
        if before:
            self._log_changes(before)
        return res

    def _log_changes(self, before):
        """A history row for every value that actually changed: the cell's
        label, what it was, what it is now. The reason comes from the popup
        (context vk_reason) or stays empty for a hand edit in the table."""
        labels = {f: self._fields[f].string for f in self.LOGGED}
        sel = dict(self._fields['stage_manual'].selection)
        for rec in self:
            for k, old in before.get(rec.id, {}).items():
                new = rec[k]
                if old == new:
                    continue
                if k == 'stage_manual':
                    old, new = sel.get(old, old), sel.get(new, new)
                elif k.startswith('price_'):
                    old, new = '%g' % (old or 0), '%g' % (new or 0)
                rec.matrix_id._log(labels[k], old, new, code=rec.code, line=rec)

    # ------------------------------------------------------------------
    # computes
    # ------------------------------------------------------------------
    @api.depends('unit_ids')
    def _compute_unit_count(self):
        for rec in self:
            rec.unit_count = len(rec.unit_ids)

    @api.depends('code')
    def _compute_code_parts(self):
        for rec in self:
            parts = [p.strip() for p in (rec.code or '').split('-')]
            if len(parts) == 3:
                rec.block, rec.view_class, rec.layout = parts
            elif not rec.code:
                rec.block = rec.view_class = rec.layout = False

    @api.depends('unit_ids.vk_state')
    def _compute_qty_sold(self):
        """Sold and priced-reservation counts read from the line's units, so
        the stage and the current price follow every sale and every
        reservation, and a cancelled one gives the unit back (D-68). A line
        without units (a sheet whose flats are not here) keeps its typed
        numbers."""
        for rec in self:
            if rec.unit_ids:
                states = rec.unit_ids.mapped('vk_state')
                rec.qty_sold = states.count(SOLD_STATE)
                rec.qty_reserved = states.count(RESERVED_STATE)
            else:
                rec.qty_sold = rec.qty_sold
                rec.qty_reserved = rec.qty_reserved

    @api.depends('qty_total', 'qty_sold', 'qty_reserved')
    def _compute_qty_left(self):
        for rec in self:
            rec.qty_taken = (rec.qty_sold or 0) + (rec.qty_reserved or 0)
            rec.qty_left = (rec.qty_total or 0) - rec.qty_taken

    @api.depends('qty_sold', 'qty_reserved', 'unit_ids')
    def _compute_qty_taken_peak(self):
        """The most units the type ever had off the market. The stage is read
        from this, not from today's count, so a cancelled sale or reservation
        never takes a type back to a cheaper stage (D-71). A line without
        units is typed by hand and follows the typed numbers: a typo must
        not lock a stage."""
        for rec in self:
            taken = (rec.qty_sold or 0) + (rec.qty_reserved or 0)
            old = rec.qty_taken_peak if isinstance(rec.id, int) else 0
            rec.qty_taken_peak = max(old or 0, taken) if rec.unit_ids else taken

    @api.depends('qty_taken_peak', 'qty_total', 'stage_manual', 'matrix_id.stage_count',
                 *['qty_%d' % i for i in range(1, MAX_STAGES + 1)],
                 *['price_%d' % i for i in range(1, MAX_STAGES + 1)])
    def _compute_price_current(self):
        """The stage by hand when one is picked, else from the sales: the
        first qty_1 sales at price_1, the next qty_2 at price_2, ... A stage
        with no price inherits the previous one; past every stage the last
        price still applies. Sales are counted at their peak (D-71)."""
        moved = []
        for rec in self:
            real = isinstance(rec.id, int)
            # the stored values before this compute: a change of stage is
            # announced in the matrix's chatter (D-71)
            old_stage, old_price = (rec.stage_current, rec.price_current) if real else (0, 0.0)
            stages = rec._stages()
            n = len(stages)
            manual = bool(rec.stage_manual and rec.stage_manual != 'auto')
            taken = rec.qty_taken_peak or 0
            stage, price = stage_of(stages, taken, rec.stage_manual if manual else None)
            # announced only when the price really changes between two set
            # prices: a matrix being set up (prices 0) or a stage that carries
            # the same price is no news for the sales team
            if (real and old_stage and old_stage != stage and old_price and price
                    and float_compare(old_price, price, precision_digits=2) != 0):
                moved.append((rec.id, old_stage, old_price))
            rec.stage_current = stage
            rec.price_current = price
            rec.stage_label = '%s ეტაპი%s' % (ROMAN[stage - 1], ' (ხელით)' if manual else '')
            # sales still needed before the next stage: the end of the
            # current stage minus what is sold; none on the last stage or
            # when the stage is pinned by hand
            if manual or stage >= n:
                rec.qty_to_next = 0
            else:
                end = sum((q or 0) for q, _p in stages[:stage])
                rec.qty_to_next = max(end - taken, 0)
        # a new price, a new stage or a unit that changed status: the free
        # units follow at the end of the transaction (D-69)
        synced = self.filtered(lambda r: isinstance(r.id, int) and r.matrix_id.sync_prices)
        if synced:
            _before_commit(self.env, 'vertikali_price_matrix.price_sync', synced.ids,
                           lambda env, ids: env['vertikali.price.matrix.line'].browse(set(ids))
                           .exists()._vk_sync_unit_prices())
        if moved:
            _before_commit(self.env, 'vertikali_price_matrix.stage_moves', moved,
                           lambda env, items: env['vertikali.price.matrix.line']._vk_announce_stages(items))

    # ------------------------------------------------------------------
    # prices onto the units (D-69), stage news (D-71)
    # ------------------------------------------------------------------
    @api.model
    def _vk_announce_stages(self, items):
        """Post each change of stage in the matrix's chatter: the type, the
        stage it was on and is on now, the price per m² before and after,
        and whether the free units were repriced. A note, notifying nobody:
        the team reads it in the chatter, no e-mail goes out (D-72).
        items = [(line_id, old_stage, old_price), ...]; a line that moved
        twice in one transaction is announced once, from its first stage."""
        first = {}
        for line_id, old_stage, old_price in items:
            first.setdefault(line_id, (old_stage, old_price))
        lines = self.browse(list(first)).exists()
        for line in lines:
            old_stage, old_price = first[line.id]
            if old_stage == line.stage_current:
                continue
            up = line.stage_current > old_stage
            body = Markup(
                '<p><b>%s</b>: %s → <b>%s</b>%s</p><p>ფასი მ²: %s → <b>%s</b></p><p>%s</p>') % (
                line.code, ROMAN[old_stage - 1] + ' ეტაპი', line.stage_label,
                '' if up else ' (უკან)',
                _money(old_price), _money(line.price_current),
                'თავისუფალი ბინების ფასი განახლდა (CRM, გაყიდვები).' if line.matrix_id.sync_prices
                else 'ბინების ფასი არ შეცვლილა - „ფასები ბინებზე“ გამორთულია.')
            line.matrix_id.message_post(
                body=body, subject='%s - %s' % (line.matrix_id.name, line.stage_label),
                message_type='notification', subtype_xmlid='mail.mt_note')

    def _vk_price_new_units(self, units):
        """A unit that joins the type takes the stage it joins: its price is
        the current price per m² × its area (D-71). Only with the prices on
        and only a unit on the market. Returns how many were priced."""
        self.ensure_one()
        target = self.price_current
        if not self.matrix_id.sync_prices or not target:
            return 0
        free = units.filtered(lambda u: u.vk_state == 'available')
        for unit in free:
            unit.sudo().write({'list_price': round(target * (unit.vk_area_total or 0.0), 2),
                               'vk_pm_price_base': target})
        return len(free)

    def _vk_sync_unit_prices(self):
        """Bring the free units of each line to the line's current price per
        m², by the difference from the price each unit was last brought to.

        Only units on the market move: a sold or reserved unit keeps the
        price it was sold or booked at (D-53). A unit with no recorded base
        takes the current price as its base and keeps its list price -- the
        first price a type gets is where its units already stand."""
        for line in self:
            target = line.price_current
            if not line.matrix_id.sync_prices or not target:
                continue
            moved = {}
            for unit in line.unit_ids.filtered(lambda u: u.vk_state == 'available'):
                base = unit.vk_pm_price_base
                if not base:
                    unit.vk_pm_price_base = target
                    continue
                if float_compare(base, target, precision_digits=2) == 0:
                    continue
                unit.write({
                    'list_price': round(unit.list_price + (target - base) * (unit.vk_area_total or 0.0), 2),
                    'vk_pm_price_base': target,
                })
                moved[base] = moved.get(base, 0) + 1
            for base, count in moved.items():
                line.matrix_id._log('ბინების ფასი მ² (%d ბინა)' % count, '%g' % base, '%g' % target,
                                    code=line.code, line=line, reason='ავტომატური: %s' % line.stage_label)

    @api.constrains('stage_manual', 'matrix_id', *['price_%d' % i for i in range(1, MAX_STAGES + 1)])
    def _check_stage_manual(self):
        """A stage picked by hand must exist in this matrix and carry a price,
        otherwise the pick would change nothing and confuse everybody."""
        for rec in self:
            if not rec.stage_manual or rec.stage_manual == 'auto':
                continue
            i, n = int(rec.stage_manual), _n(rec.stage_count)
            if i > n:
                raise ValidationError("ამ მატრიცას მხოლოდ %d ეტაპი აქვს - %s ეტაპი არ არსებობს (ტიპი %s). "
                                      "ეტაპი „მატრიცის ფორმირებიდან“ დაამატე." % (n, ROMAN[i - 1], rec.code))
            if not rec['price_%d' % i]:
                raise ValidationError("%s ეტაპს ფასი არ აქვს (ტიპი %s) - ჯერ ფასი ჩაწერე, მერე აირჩიე ეტაპი."
                                      % (ROMAN[i - 1], rec.code))

    @api.constrains('qty_total', 'qty_sold', 'qty_reserved', *['qty_%d' % i for i in range(1, MAX_STAGES + 1)])
    def _check_quantities(self):
        for rec in self:
            for val in (rec.qty_total, rec.qty_sold, rec.qty_reserved,
                        *[rec['qty_%d' % i] for i in range(1, MAX_STAGES + 1)]):
                if val < 0:
                    raise ValidationError("რაოდენობა უარყოფითი არ შეიძლება იყოს (ტიპი %s)." % rec.code)
            taken = (rec.qty_sold or 0) + (rec.qty_reserved or 0)
            if taken > rec.qty_total:
                raise ValidationError("გაყიდული (%d) და დაჯავშნილი (%d) ერთად სულ რაოდენობას (%d) აღემატება (ტიპი %s)."
                                      % (rec.qty_sold, rec.qty_reserved, rec.qty_total, rec.code))
            # Typed by hand, the earlier stages may not exceed the total. The
            # formation runs with vk_trim and lets _fill_last_stage cut the
            # stages of a type that turned out smaller than the table says.
            if not self.env.context.get('vk_trim'):
                # every stage counts, the last one included: it is normally
                # the remainder, but the team may type it (D-52) and then
                # nothing else would catch a split past the type's units
                n = _n(rec.stage_count)
                parts = [(ROMAN[i - 1], rec['qty_%d' % i] or 0) for i in range(1, n + 1)]
                earlier = sum(q for _r, q in parts)
                if rec.qty_total and earlier > rec.qty_total:
                    raise ValidationError(
                        "ტიპი %s: ეტაპებზე გაწერილია %d ბინა (%s), ტიპს კი სულ %d ბინა აქვს - "
                        "%d-ით მეტია. შეამცირე რომელიმე ეტაპის რაოდენობა."
                        % (rec.code, earlier,
                           ' + '.join('%s %d' % (r, q) for r, q in parts if q),
                           rec.qty_total, earlier - rec.qty_total))

    def action_open_units(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': 'ბინები - %s' % self.code,
            'res_model': 'product.template',
            'view_mode': 'list,form',
            'domain': [('id', 'in', self.unit_ids.ids)],
            'context': {'create': False},
        }


class ProductTemplate(models.Model):
    """The matrix price per m² a free unit's list_price was last brought to
    (D-69). The next change of its type's price moves the unit by the
    difference, so the unit keeps its own spread (floor, orientation)
    and a unit that comes back from a reservation catches up."""
    _inherit = 'product.template'

    vk_pm_price_base = fields.Float(string='მატრიცის ფასი მ² (ბინაზე ჩაწერილი)', copy=False)

    # what decides which matrix line a unit belongs to (project, type) and
    # whether it is for sale; a change to one of them refreshes the matrices
    VK_MATRIX_FIELDS = ('vk_is_unit', 'categ_id', 'vk_building', 'vk_view_id', 'vk_rooms',
                        'vk_manual_state', 'active')

    def _vk_matrix_refresh(self):
        """The matrices look at these units once, before the commit (D-71)."""
        _before_commit(self.env, 'vertikali_price_matrix.unit_refresh', self.ids,
                       lambda env, ids: env['vertikali.price.matrix'].search([('project_id', '!=', False)])
                       ._vk_refresh_units(env['product.template'].browse(set(ids)).exists()))

    @api.model_create_multi
    def create(self, vals_list):
        recs = super().create(vals_list)
        units = recs.filtered('vk_is_unit')
        if units:
            units._vk_matrix_refresh()
        return recs

    def write(self, vals):
        res = super().write(vals)
        if any(f in vals for f in self.VK_MATRIX_FIELDS):
            self._vk_matrix_refresh()
        return res

    def unlink(self):
        units = self.filtered('vk_is_unit')
        res = super().unlink()
        if units:
            # nothing left to look at, but the totals of their lines shrink
            self.browse()._vk_matrix_refresh()
        return res


class VertikaliOption(models.Model):
    """The view classes of the sheet (WS, BS, ORD) live on vertikali's view
    values: one short code per view, typed once in Estate > Configuration."""
    _inherit = 'vertikali.option'

    vk_matrix_code = fields.Char(string='მატრიცის კოდი', size=8,
                                 help="ხედის კლასის კოდი ფასების მატრიცისთვის, მაგ. WS, BS, ORD.")
