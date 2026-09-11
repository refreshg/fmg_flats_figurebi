# განვადების კალკულატორი — `vertikali_payment_calc`

Instalment schedules for property sales, priced in dollars.

Standalone: it needs Sales and CRM and nothing else. Install it on any Odoo 19
database — this customer's, another company's, a different portal.

## What it does

Works out what a buyer pays and when: a deposit, a run of instalments and a
closing payment, against a flat's price.

- **Schedule types** (`vertikali.payment.plan`) are records, not code. The team
  writes `10/20/70` the way it says it, with the discount that goes with it,
  and files one away as inactive when it stops being offered.
  *CRM → Configuration → გრაფიკის ტიპები.*
- **Calculations** (`vertikali.payment.calc`) — several per deal, so
  10/20/70 against 30/0/70 can both be kept and revisited. Exactly one is
  marked `is_schedule`; marking a second clears the first, so there is never
  more than one answer to what the buyer is actually paying.
- **Lines** (`vertikali.payment.calc.line`) — the schedule itself. A row that
  falls on a Saturday or Sunday is flagged and shown in red, and left where it
  is: which way to move it is the buyer's agreement, not ours to guess.

## The discount

Quoted four ways, because all four are in use and none is a rewording of
another:

| ტიპი | სახე | what happens |
|---|---|---|
| პროცენტი | კვ.მ-ზე | the metre price settles first, the total follows from the area |
| პროცენტი | ჯამურ თანხაზე | the total settles first, the metre price follows |
| თანხა | კვ.მ-ზე | a flat sum off each metre |
| თანხა | ჯამურ თანხაზე | a flat sum off the flat |

Signed throughout: minus takes off, plus adds on. `apply_adjustment()` in
`models/payment_plan.py` is the only place the arithmetic lives, shared by the
calculation and by anything that needs to ask what a type is worth.

## Currency

The calculation is written in USD, because the contract is. Flat prices stay
in the company currency and are converted on the way in, at
`vertikali_payment_calc.nbg_usd` (Settings → Technical → System Parameters),
default `2.7178`. A company that already keeps its prices in dollars is left
alone: nothing is converted. The legacy key `vertikali_crm_config.nbg_usd` is still read,
so a rate entered before this module was split out is not lost.

## Installing somewhere else

Nothing here is specific to one customer. Two things adapt to the host:

- **The flat's area and metre price** are read from `vk_area_total` and
  `vk_price_sqm` if the database has them (the `vertikali` estate module), and
  worked out from `list_price` if it does not. See `UNIT_AREA_FIELD` in
  `models/payment_calc.py`.
- **Which products count as property** — no domain is set on `unit_id`. A host
  that wants one sets it on the view; `vertikali_crm_config` does exactly that
  in `views/payment_bridge.xml`, and moves the menus under its own Estate menu
  at the same time. Copy that file as the pattern.

## Opening it from the deal

The opportunity form carries a **განვადების კალკულატორი** button in its header
and a smart button counting the calculations already made
(`models/crm_lead.py`, `views/crm_lead_views.xml`). Where the host records the
deal's flats in `vk_unit_ids` (the `vertikali` module), one flat is filled in
and locked; several are offered as the choice; none leaves the flat to be
picked. Prices arrive through the unit onchange.

To open it from anywhere else: `vertikali.payment.calc` is an ordinary model.
Use an `ir.actions.act_window` in `target: 'new'` with `default_unit_id` and
`default_lead_id` in the context, plus `vk_unit_locked` to pin the flat.

Saving is deliberate: neither `კალკულაციის შენახვა` nor `გრაფიკის შენახვა`
appears until `გამოთვლა` has produced rows, so an empty quote cannot be filed
against a deal.
