# FIGUREBI — განვადების გრაფიკის კალკულატორი (Odoo 19)

## პროექტის კონტექსტი

დეველოპერული კომპანიის გაყიდვების პროცესისთვის Excel-ის განვადების კალკულატორი
(`research/გრაფიკის კალკულატორი - ფიგურები.xlsx`, ფურცელი „100") გადატანილია Odoo 19-ში
custom მოდულად. გაყიდვების მენეჯერი Sale Order-ზე (Quotation) შეიყვანს პარამეტრებს და
სისტემა აგენერირებს გადახდების გრაფიკს.

- **Staging**: https://communapp-com-staging-37061251.dev.odoo.com/odoo (login: admin; პაროლი → `SECRETS.local.md`; RPC-შიც პაროლი მუშაობს — houseltd-ის API key აქ არ მოქმედებს)
- **მოდული**: `addons/figurebi_installment/` (depends: `sale_management`)

## სამუშაო წესები (მომხმარებელთან შეთანხმებული)

- **Standard-first**: ყოველი მოთხოვნისთვის ჯერ მოწმდება Odoo-ს სტანდარტული გადაწყვეტა
  (Apps → Settings UI → Automation/Server Actions → Record Rules → View inherit → მხოლოდ ბოლოს Python).
  Custom კოდი იწერება მხოლოდ კონკრეტული მოდელის/მენიუს დასახელებული შემოწმების შემდეგ.
- გეგმა (checklist) იწერება კოდამდე და ელოდება დადასტურებას; ერთ ჯერზე ერთი ამოცანა.
- პასუხები ქართულად, კოდის კომენტარები ინგლისურად.

## ტერმინოლოგია

| ქართული | ტექნიკური | განმარტება |
|---|---|---|
| შიდა განვადება | `payment_type='installment'` | ტრანში + გრაფიკი + ნაშთი ბოლოს |
| ბანკის სესხი | `payment_type='bank_loan'` | მთლიანი თანხა ერთ გადახდად (ბანკიდან) |
| ერთიანი გადახდა | `payment_type='full_payment'` | მთლიანი თანხა ერთ გადახდად |
| პირველი ტრანში | `first_tranche_amount` | პირველი%-ის თანხა, პირველი გადახდის თარიღზე |
| გრაფიკით გადაიხდის | `schedule_amount` | გრაფიკის%-ის თანხა, თვიურ შენატანებად |
| ნაშთი / balloon | `final_balloon_amount` | ჯამი − ტრანში − გრაფიკი; ბოლო გადახდაა |
| ობიექტის კოდი | product default_code | მაგ. APAR/I/512 (კორპუსი/სადარბაზო/N) |

## გრაფიკის ლოგიკა (Excel-ის ერთგული)

1. სტრიქონი 1: პირველი ტრანში = ROUND(პირველი% × ჯამი, 2), პირველი გადახდის თარიღზე.
2. თარიღები: გრაფიკის დაწყების დღიდან ყოველ N თვეში იმავე რიცხვში; ბოლო თარიღი
   იჭრება პროექტის დასრულების თვის **15 რიცხვზე**; დასრულების თარიღს გადაცილებული
   თარიღები აღარ გენერირდება.
3. შენატანი = ROUND(გრაფიკის თანხა ÷ რაოდენობა, 2); **ბოლო სტრიქონი ყოველთვის ნაშთია**
   (ჯამი − აქამდე გადახდილი) — შთანთქავს balloon-საც და დამრგვალების ცდომილებასაც.
4. საცნობარო PMT: ანუიტეტი დარჩენილ თანხაზე (default: 14%, 120 თვე).

## მიღებული გადაწყვეტილებები

- **კალკულატორი Sale Order-ზეა** (არა CRM lead-ზე) — ფასი/ფასდაკლება იქაა, CRM-დან სტანდარტულად იქმნება.
- **თითო ბინა = პროდუქტი**: ერთეული მ², ფასი = კვ.მ ფასი, ხაზზე qty = ფართი;
  ფასდაკლება — სტანდარტული discount ველი; ჯამური ფასი = `amount_total`.
- **შაბათ-კვირის წესი შეცვლილია Excel-თან შედარებით** (მომხმარებლის მითითებით):
  თარიღი ავტომატურად აღარ გადაიწევს — სტრიქონი წითლდება (`is_weekend`) და მენეჯერი
  ხელით ასწორებს ორშაბათზე ან პარასკევზე. (Excel +2 დღეს უმატებდა.)
- ორივე % თავისუფლად შეყვანადია; თუ ჯამი <100%, სხვაობა ბოლო გადახდაა (balloon).
- ეტაპი 1 = მხოლოდ დათვლა/ჩანაწერი. მომდევნო ეტაპები: PDF (QWeb), ინვოისები გრაფიკიდან,
  ობიექტების ბაზის იმპორტი, ჯავშნები (3-დღიანი ფასის დაფიქსირება, მოხსნის მიზეზი სავალდებულო).

## ვალიდაცია

ალგორითმი გადამოწმებულია Excel-ის მაგალითზე: ჯამი 70,000, 10%+10%, დაწყება 2026-08-10,
დასრულება 2026-12-30 → 7,000 (2026-07-10) + 4×1,750 (10 რიცხვებში) + 56,000 (2026-12-10). ✓

## დეპლოი (შესრულებული — git-ის გარეშე)

მომხმარებლის მოთხოვნით დეპლოი მოხდა **GitHub-ის გარეშე**, JSON-RPC API-თ, Odoo-ს
„manual" მექანიზმებით (იგივე პრიმიტივები, რასაც Studio იყენებს):

⚠️ **ისტორია**: თავდაპირველად შეცდომით დაყენდა houseltd-staging-36920288-ზე — იქიდან
ყველაფერი სრულად წაიშალა (`scripts/cleanup-houseltd.ps1`) და გადმოვიდა communapp-ზე.

- **მოდელი**: `x_figurebi_installment_line` (ir.model id=1471) — x_order_id, x_number,
  x_date, x_amount, x_is_weekend (computed)
- **ველები sale.order-ზე**: x_payment_type (selection), x_first_tranche_pct, x_schedule_pct,
  x_first_payment_date, x_schedule_start_date, x_schedule_interval, x_project_end_date,
  x_bank_rate, x_bank_term_months, computed: x_first_tranche_amount, x_schedule_amount,
  x_final_balloon_amount, x_bank_pmt_reference, one2many: x_installment_line_ids
- **Server Action** „FIGUREBI: გრაფიკის გენერაცია" (id=1035) — გენერაციის ლოგიკა (safe_eval Python)
- **View**: `sale.order.form.figurebi.installment` — გვერდი „განვადების გრაფიკი" Quotation-ზე
- **Defaults**: installment / 10% / 10% / ინტერვალი 1 / 14% / 120 თვე (ir.default)
- **უფლებები**: sales_team.group_sale_salesman — სრული CRUD ხაზებზე

სკრიპტები (განმეორებადი, idempotent):
- `scripts/deploy-jsonrpc.ps1` — სრული დეპლოი (ხელახლა გაშვება არსებულს აახლებს)
- `scripts/add-test-data.ps1` — სატესტო ბინები (მ² ერთეულით), კლიენტები, demo quotation
- `scripts/test-schedule.ps1` — end-to-end ტესტი (ჯერ კიდევ houseltd-ზეა მიმართული — გაშვებამდე შეცვალეთ base/db/key)
- `scripts/cleanup-houseltd.ps1` — houseltd-ის გასუფთავება (უკვე შესრულებულია)

⚠️ PowerShell სკრიპტები ქართული ტექსტით ინახება **UTF-8 BOM**-ით (PS 5.1-ის მოთხოვნა).
⚠️ Odoo 19: sale.order.line-ზე გადასახადის ველია `tax_ids` (არა `tax_id`).
⚠️ Server Action-ის sandbox (safe_eval) კრძალავს ატრიბუტზე მინიჭებას (`rec.field = x` → STORE_ATTR error) — გამოიყენე `rec['field'] = x`.
⚠️ PowerShell 5.1 ერთელემენტიან JSON მასივს სკალარად „შლის" — RPC შედეგები შემოახვიე `@(...)`-ში `.Count`-ის შემოწმებამდე.

## PDF გრაფიკი კლიენტისთვის (დამატებულია 2026-08-27)

- QWeb შაბლონი: ir.ui.view type=qweb, key=`x_figurebi.report_installment` + ir.model.data
  xmlid (module=x_figurebi, name=report_installment) — ორივე საჭიროა template-ის საპოვნელად
- ir.actions.report „განვადების გრაფიკი" (qweb-pdf, sale.order-ის **Print** მენიუში)
- შიგთავსი: კლიენტი/მენეჯერი, ობიექტის ცხრილი (ფართი/ფასი/ფასდ.), გადახდის პირობები,
  გრაფიკის ცხრილი ჯამით, საბანკო PMT სქოლიო, „საინფორმაციო" დისკლეიმერი
- ქართული ფონტები PDF-ში მუშაობს; კომპანიის ლოგო Settings-ში უნდა აიტვირთოს
- სკრიპტი: `scripts/add-pdf-report.ps1`; ტესტი: PDF ჩამოიტვირთა და ვიზუალურად შემოწმდა ✓

## ვიზუალის საბოლოო მდგომარეობა (2026-08-27, მომხმარებელთან iterations-ით დასრულებული)

- **ყველა layout-სტილი inline-ა** (style= ატრიბუტები arch-ში) — CSS asset-ზე დამოკიდებულება მოხსნილია
  (asset მხოლოდ სიის სტრიქონების ფონებს ამატებს); მიზეზი: asset-ქეში სტილებს „კარგავდა"
- **ფერების წესი**: მხოლოდ 1-ლი (საინფო) რიგის 4 ბარათია ცისფერი (#f2f4ff); ყველა დანარჩენი
  ბარათი **თეთრია** (#ffffff) ცისფერი ჩარჩოთი — ნიმუშის ვიჯეტის მიხედვით
- საბოლოო განლაგება ტაბზე „გადახდის კალკულატორი":
  1. 🟦 დილი | უძრავი ქონების №/მ² | საწყისი კვ.მ | საწყისი ჯამური → **გამყოფი ხაზი**
  2. ⬜ გადახდის ტიპი | გადახდის პერიოდულობა | გადანაწილების ვადა (თვე) — calc(25%-11px)
  3. ⬜ ფასდაკლება (%) | ფასდაკლება კვ.მ ($) | ფასდაკლება სრული ($) | საბოლოო კვ.მ | საბოლოო ფასი
  4. სექცია **„შენატანები და თარიღები"** (underline):
     ⬜ პირველადი შენატანის თარიღი | $ | % | განვადების დაწყების თარიღი
     ⬜ ბოლო შენატანის თარიღი | $ | % | ბოლო გადახდის თარიღი (x_schedule_end_date, RO)
     ⬜ პროექტის დასრულების თარიღი — **ცალკე რიგში**, 25% სიგანე (სიმეტრიისთვის)
  5. „დამატებითი პარამეტრები" (მხოლოდ „გრაფიკით გადაიხდის" წყვილი) | „საბანკო (საცნობარო)"
  6. ღილაკები: გრაფიკის გენერაცია / შაბ-კვ გასწორება / ინვოისების გენერაცია → გრაფიკი (N/თარიღი/თანხა/ნაშთი)
- ცნობილი UX-შეზღუდვა: $↔% და ფასდაკლების გადათვლა ხდება Save-ზე; ეკრანის ბარათები ზოგჯერ
  F5-ს ითხოვს (automation სერვერზე წერს, client cache ძველია) — გადამოწმებულია, რომ სერვერზე
  ციფრები ყოველთვის სწორია
- invisible-ატრიბუტიანი ბარათების სტილი ცალკე შაბლონით ინიშნება — ჩვეულებრივი replace ვერ ხედავს
- **საბანკო ჯგუფი ჩანს installment+bank_loan-ზე** — მომხმარებელს ვკითხე მხოლოდ ბანკზე დავმალო
  თუ არა; პასუხი ჯერ არ მიუცია, დარჩა როგორც იყო (ღია საკითხი)

## პერიოდულობის ჩამოსაშლელი + ტაბის სახელი (2026-08-27)

- `x_periodicity` (selection: 1/2/3/6/12 → „თვეში ერთხელ"…„წელიწადში ერთხელ", default '1')
  ცალკე ხაზზე ბარათების ქვეშ; ძველი x_schedule_interval UI-დან ამოღებულია (DB-ში რჩება,
  გენერაცია fallback-ად იყენებს); snapshot-ის ხელმოწერა პერიოდულობაზეა (ორივე ადგილას)
- ტაბს ეწოდა **„გადახდის კალკულატორი"** (იყო „განვადების გრაფიკი")
- View arch **v13** + გენერაციის კანონიკური კოდი (v5): `scripts/add-periodicity.ps1`
- ტესტი: პერიოდულობა „ორ თვეში ერთხელ" → 2-თვიანი ნახტომები, ჯამი ზუსტი ✓
- პერიოდულობა და ფასდაკლების რიგი ბარათების სტილშია: მე-2 რიგში გადახდის ტიპი +
  პერიოდულობა (ორივე ბარათებში; ტიპი params ჯგუფიდან ამოღებულია); ფასდაკლების რიგი —
  5 ბარათი (ფასდ. კვ.მ $ | ფასდ. სრული $ | **ფასდაკლება %** `x_discount_pct` შეყვანადი |
  საბოლოო კვ.მ ფასი `x_final_price_per_m2` | საბოლოო ფასი amount_total)
- ფასდაკლების სამმხრივი სინქრონი: $/კვ.მ ↔ $/სრული ↔ % ↔ ხაზის Disc.% — **სამი automation**
  (`figurebi_disc` გუშაგით), თითო ველს თავისი trigger-ი აქვს და **შეცვლილი ველი ყოველთვის
  იმარჯვებს**: C1 per_m2-master, C2 total-master (`scripts/fix-discount-priority.ps1` —
  კანონიკური), D pct-master (`scripts/add-discount-pct.ps1`); ფასდაკლების რიგში % ბარათი პირველია
- **ფასნამატი (2026-08-28)**: მინუსიანი მნიშვნელობა ფასდაკლების ველებში = ფასის მომატება
  (მაგ. pct=-5 → ხაზის Disc.%=-5, ჯამი 67,780.54→71,169.56 ✓); ლიმიტი მხოლოდ pct≤100;
  ბარათებს ჰქვია „ფასდაკლება / ფასნამატი"; მიზეზი: არასტანდარტული გადანაწილება (20/50/30)
  ხშირად განსხვავებულ ფასთან ერთად
- **შენატანების სექცია ბარათებად** (სათაური `.figurebi_section` „შენატანები და თარიღები"):
  რიგი 1 — პირველადი შენატანის თარიღი | $ | % | განვადების დაწყების თარიღი;
  რიგი 2 — ბოლო შენატანის თარიღი | $ | % | პროექტის დასრულების თარიღი.
  ძველი „პარამეტრები"/„განვადების სტრუქტურა" group-ები ამოღებულია; დარჩა „დამატებითი
  პარამეტრები" (გადანაწილების ვადა, გრაფიკის დასრულება, გრაფიკით გადაიხდის წყვილი) + საბანკო

## ჰედერის ბარათები ნიმუშის სტილში (2026-08-27)

- ტაბის თავში 4 ბარათი (flex, ღია ლურჯ-იასამნისფერი ფონი, ლურჯი bold მნიშვნელობები):
  დილი (ორდერის name) | უძრავი ქონების №/მ² (`x_object_ref` computed: default_code + qty) |
  საწყისი კვ.მ ღირებულება (`x_price_per_m2` computed: ხაზის price_unit) | საწყისი ჯამური (`x_initial_total`)
- CSS ბარათებისთვის იმავე attachment-შია (id=2008, სრული გადაწერით — ძველი წესებიც შიგნითაა)
- „ფასი და ფასდაკლება" ჯგუფიდან x_initial_total ამოღებულია (ჰედერშია), ჯგუფს ჰქვია „ფასდაკლება"
- View arch **v12** კანონიკური: `scripts/add-header-cards.ps1`
- ტესტი: S01058 → "APAR/II/101 / 75 მ²", 1400, 105000 ✓

## თარიღების ბოლო დახვეწები (2026-09-01)

- **„ბოლო გადახდის თარიღი" ბარათი ჩაწერადია** (მომხმარებლის მოთხოვნით): ახლა ის
  `x_final_payment_date`-ს აჩვენებს (balloon-გადახდის თარიღი, ცარიელი = დასრულების თვის 15);
  ხოლო რიგის პირველ ბარათს ჰქვია **„გრაფიკის ბოლო შენატანი (ავტო)"** და computed
  `x_schedule_end_date`-ს აჩვენებს. მე-2 რიგი: გრაფიკის ბოლო შენატანი (ავტო) 🔒 | ბოლო
  შენატანი $ | ბოლო შენატანი % | ბოლო გადახდის თარიღი ✏️
- **x_schedule_end_date პროგნოზირებს გენერაციამდეც**: თუ გრაფიკი არაა, მაგრამ დაწყების
  თარიღი + გადანაწილების ვადაა შეყვანილი → დაწყება + (count−1)×interval (count = ვადა //
  პერიოდულობა); გრაფიკის არსებობისას — max(lines.x_date), როგორც იყო. კანონიკური compute:
  `scripts/add-schedule-end-date.ps1` (ველის განსაზღვრება); view კვლავ add-periodicity.ps1-შია
- **ბოლო გადახდის თარიღის ავტო-სინქრონი** (automation id=29, `scripts/add-final-date-sync.ps1`):
  გადანაწილების ვადის / დაწყების თარიღის / პერიოდულობის შეცვლისას (installment ტიპზე,
  ვადა>0) x_final_payment_date ავტომატურად დგება ბოლო შენატანის **მომდევნო პერიოდზე**
  (დაწყება + count×interval — ექსელისებურად, ნაშთი გრაფიკის მომდევნო რიგზე); გუშაგი
  `figurebi_final_sync`; თარიღის პირდაპირი ხელით ჩაწერა რჩება (ის trigger-ს არ ეხება)
- ტესტები: დაწყება 02.09.2026 + 10თვე → ავტო-ბოლო 02.06.2027, ბოლო გადახდა 02.07.2027 ✓;
  6 თვეზე შეცვლა → 02.02.2027 / 02.03.2027 ✓; ხელით 15.04.2027 → დარჩა ✓;
  პერიოდულობა „ორ თვეში ერთხელ" პროგნოზშიც გათვალისწინებულია ✓
- ⚠️ view-ს ეს ცვლილებები add-periodicity.ps1-შია ჩაშენებული (label swap + editable ბარათი);
  add-schedule-end-date.ps1-ის view-ნაწილი (v8) მოძველებულია — ის სკრიპტი მხოლოდ ველის
  compute-ისთვის გამოიყენეთ, view-სთვის ყოველთვის add-periodicity.ps1

## CRM: ლიდების ენით განაწილება (დამატებულია 2026-08-28)

- **წესი**: ლიდის Language (სტანდარტული crm.lead.lang_id) → en* = **„ელენე (ინგლისური)"**
  (user id=2621, login en.manager.test); ka/ცარიელი/სხვა = **„დავითი (ქართული)"** (id=2622,
  ka.manager.test). რუსული **გამოირიცხა** მომხმარებლის გადაწყვეტილებით.
  (ჯერ „EN/KA მენეჯერი (ტესტი)" ერქვათ — მომხმარებლის თხოვნით რეალური სახელები + ენის მინაწერი)
- base.automation (id=28) crm.lead-ზე, trigger: create + lang_id-ის ცვლილება;
  context-გუშაგი `figurebi_crm_assign`
- **ხელით არჩევანი პატივდებულია**: თუ ლიდზე user_id უკვე სხვა პირია (არა შემქმნელი და
  არა ორი სატესტო მენეჯერი), automation არ ეხება; user_id-ის ხელით შეცვლა ენის შეუცვლელად
  ყოველთვის რჩება (trigger მხოლოდ lang_id-ზეა)
- Rule-Based Assignment (სტანდარტული) განზრახ არ გამოვიყენეთ — პერიოდულია და ბალანსით
  არიგებს, მყისიერი ზუსტი მინიჭება automation-ით ჯობდა (გეგმა დამტკიცდა plan mode-ში)
- სატესტო მენეჯერები რეალურ გადატანისას შეიცვლება; ლიდები ამჟამად ხელით შეაქვთ
- სკრიპტი: `scripts/add-crm-lang-assign.ps1`; ტესტები: en→EN ✓, ka→KA ✓, ცარიელი→KA ✓,
  ხელით არჩეული შენარჩუნდა ✓, შემდგომი ხელით გადაბარება შენარჩუნდა ✓
- ⚠️ Odoo 19: res.users-ზე ჯგუფების ველია `group_ids` (არა `groups_id`)
- ⚠️ crm.lead.lang_id **computed** ველია — create-ზე გადაცემულ ენას ზოგჯერ გადააწერს
  (en_US default-ით); RPC-თ ლიდის შექმნისას ენა **ცალკე write-ით** ჩაწერე შექმნის შემდეგ
- **სატესტო ლიდები staging-ზე** (ids 24-28): 2 ინგლისური→ელენე, 2 ქართული→დავითი,
  1 უენო→დავითი; ლიდი id=23 („სატესტო's opportunity") მომხმარებლის ხელით შექმნილია

## ბანკის სესხის დაყოფა (დამატებულია 2026-08-28, მომხმარებლის დასტურით)

- **ბანკის სესხი = 2 სტრიქონი** (ექსელის ტერმინოლოგიით): თანამონაწილეობა (x_first_tranche
  ველების ხელახალი გამოყენება — $/% სინქრონი მუშაობს) პირველი გადახდის თარიღზე +
  სესხის თანხა (ჯამი − თანამონაწილეობა) `x_bank_transfer_date`-ზე (ცარიელი = იმავე დღეს);
  0 თანამონაწილეობისას — 1 სტრიქონი
- ახალი ველები: `x_bank_transfer_date` (date), `x_bank_loan_amount` (computed, RO)
- ბანკის ბარათების რიგი „შენატანები და თარიღები"-ში, ჩანს მხოლოდ bank_loan-ზე:
  თანამონაწილეობა $ | % | სესხის თანხა | სესხის ჩარიცხვის თარიღი
- **PMT გადაკეთდა**: bank_loan → პრინციპალი = სესხის თანხა; installment → ბოლო გადახდის თანხა
- snapshot-ის ხელმოწერას დაემატა x_bank_transfer_date (ორივე ადგილას)
- სკრიპტები: `scripts/add-bank-split.ps1` (ველები+PMT) + კანონიკური `add-periodicity.ps1`
- ტესტი: 20% თანამონაწილეობა → 13,556.11 (10.09) + 54,224.43 (01.10), ჯამი ზუსტი,
  PMT=841.92 სესხის თანხაზე ✓

## კალკულატორი v2 — ნიმუშის მიხედვით გადაწყობა (2026-08-27)

მომხმარებელმა მოიტანა საორიენტაციო ვებ-კალკულატორის ნიმუში; სამივე კითხვაზე დაადასტურა:
$↔% ორმხრივი შეყვანა, ბოლო შენატანის ხელით თარიღი, ფასდაკლება დოლარებში.

**ახალი მოდელი:**
- პირველი ტრანში და ბოლო გადახდა: ორივე ველი ($ და %) **შეყვანადია** — ერთმანეთს
  base.automation-ებით სინქრონდებიან (`figurebi_sync` context-გუშაგით): %→$ (trigger: pct-ები +
  amount_total), $→% (trigger: თანხები). amount_total-ის ცვლილებაზე %-ია მთავარი.
- **გრაფიკით გადაიხდის = computed remainder** (100 − ტრანში% − ბოლო%); აღარ შეიყვანება.
  x_schedule_pct-ის ძველი ir.default წაშლილია; ახალი default: ბოლო% = 80.
- `x_final_payment_date` — ბოლო შენატანის თარიღი ხელით; ცარიელი = დასრულების თვის 15 (ძველი წესი).
  ვალიდაციები: გრაფიკის ბოლო შენატანზე გვიან უნდა იყოს **და** პროექტის დასრულებაზე გვიან ვერ
  იქნება (≤ x_project_end_date; დაემატა 2026-08-28, ტესტით: გვიანი დაიბლოკა, ტოლი გავიდა ✓).
- **ფასდაკლება დოლარებში**: x_discount_per_m2 / x_discount_total — automation წერს პირველი
  ხაზის Disc.%-ს და მეორე ველს აირეკლავს (`figurebi_disc` გუშაგი); x_initial_total (computed) =
  ფასდაკლებამდე ჯამი; ჯგუფი „ფასი და ფასდაკლება" ტაბზე.
- გენერაცია (canonical v4): ტრანში + n თანაბარი შენატანი (ბოლო schedule-სტრიქონი ცენტებს
  შთანთქავს) + ბოლო გადახდა თავის თარიღზე. snapshot-ის ხელმოწერა შეიცვალა (თანხებზეა
  დაფუძნებული) — კვლავ ორ ადგილასაა და იდენტური უნდა დარჩეს.
- View arch **v11** კანონიკური: `scripts/rework-calculator-v2.ps1`; ტესტები: `scripts/test-calculator-v2.ps1`
- ტესტები: %→$ create-ზე ✓; $10,000→14.7535% ✓; $ფასდაკლება→Disc.5%+per_m2 65.05 ✓;
  გენერაცია balloon-ით ხელით თარიღზე (2027-12-30), sum ზუსტი, ნაშთი 0 ✓; ადრეული ბოლო თარიღი დაიბლოკა ✓

## %+თანხის წყვილები და ბოლო გადახდის % (დამატებულია 2026-08-27)

- `x_final_balloon_pct` (computed): 100 − ტრანშის% − გრაფიკის%
- ლეიაუტი შეიცვალა: „განვადების სტრუქტურა" ჯგუფში სამი წყვილი ერთ-ერთ ხაზზე —
  ტრანში `8% = 4,892.40`, გრაფიკით `15% = ...`, ბოლო გადახდა `77% = ...` (o_row + oe_inline)
- საბანკო ველები ცალკე ჯგუფში „საბანკო (საცნობარო)"
- View arch **v10**-ის კანონიკური ვერსია: `scripts/add-paired-percents.ps1`

## ნაშთის სვეტი გრაფიკში (დამატებულია 2026-08-27)

- `x_balance` (computed, read-only) ხაზზე: amount_total − აქამდე (x_number-ით) გადახდილი;
  ბოლო სტრიქონზე 0
- View arch **v9**-ის კანონიკური ვერსია: `scripts/add-balance-column.ps1`
- ტესტი: S01058 → 94,500 → ... → 84,000 → 0 ✓

## გრაფიკის დასრულების თარიღი (დამატებულია 2026-08-27)

- `x_schedule_end_date` (computed, read-only): ბოლო შენატანის ზუსტი თარიღი — max(lines.x_date);
  ჩანს დაწყების თარიღის ქვეშ, მხოლოდ გრაფიკის არსებობისას
- View arch **v8**-ის კანონიკური ვერსია: `scripts/add-schedule-end-date.ps1`
- ტესტი: S01058 → 2027-08-15 ✓

## გადანაწილების ვადა ხელით (დამატებულია 2026-08-27)

- ველი `x_schedule_months` („გადანაწილების ვადა (თვე)", integer, არასავალდებულო):
  ცარიელი/0 = ავტომატური რეჟიმი (დასრულებამდე, ძველი ლოგიკა); N = გრაფიკის ნაწილი
  ზუსტად N თვეზე ნაწილდება, balloon კვლავ დასრულების cap-თან (თვის 15) რჩება
- ვალიდაცია: თუ N-თვიანი გადანაწილება დასრულებას სცდება → UserError
- ⚠️ snapshot-ის ხელმოწერას დაემატა months — ფორმატი კვლავ ორ ადგილასაა (action + compute)
  და იდენტური უნდა დარჩეს
- View arch **v7** + გენერაციის action-ის კანონიკური კოდი: `scripts/add-manual-months.ps1`
- ტესტები: 6 თვე → ტრანში + 6×1129.67 + balloon 54224.47 დასრულებაზე, ჯამი ზუსტი ✓;
  ავტო-რეჟიმი უცვლელი ✓; ზედმეტად გრძელი ვადა დაიბლოკა ✓

## იასამნისფერი სტრიქონების სტილი (დამატებულია 2026-08-27)

- CSS ატვირთულია public ir.attachment-ად (id=2008) და დარეგისტრირებულია
  `web.assets_backend`-ში ir.asset ჩანაწერით (id=106) — git-ის გარეშე asset-ის დამატების გზა
- სტილი: auto-fixed სტრიქონები — bold მუქი იასამნისფერი ტექსტი + ღია იასამნისფერი ფონი;
  წითელი სტრიქონებიც bold
- სკრიპტი: `scripts/add-purple-style.ps1`

## ინვოისები მხოლოდ დადასტურებულ ორდერზე (დამატებულია 2026-08-27)

- ინვოისების გენერაცია Quotation-ზე აკრძალულია: server action ამოწმებს `state != 'sale'` →
  UserError „ჯერ დაადასტურეთ (Confirm) შეთავაზება"; ღილაკიც დამალულია `state != 'sale'`-ზე
- სწორი თანმიმდევრობა: გრაფიკი → წითლების გასწორება → Send → **Confirm** → ინვოისები
- View arch **v6** + ინვოისების action-ის კანონიკური კოდი: `scripts/add-invoice-state-guard.ps1`
- ტესტი: draft-ზე დაიბლოკა ✓; weekend-გასწორება → Confirm → გენერაცია → 8 ინვოისი ✓

## შაბ-კვ თარიღების ავტო-გასწორება (დამატებულია 2026-08-27)

- ღილაკი **„შაბ-კვ თარიღების გასწორება"** (btn-warning, ჩანს მხოლოდ წითელი ხაზების არსებობისას,
  server action id=1042): ყველა weekend თარიღი → ორშაბათი (შაბ +2, კვ +1)
- გასწორებული სტრიქონები **იასამნისფრად** ინიშნება: x_auto_fixed (boolean) + `decoration-primary`
- **ხელით შესწორება იასამნისფერს ხსნის**: base.automation (id=22) line-ის x_date-ზე;
  ავტო-გასწორების action წერს `with_context(figurebi_autofix=True)`-ით და automation ამ
  context-ის write-ებს აიგნორებს — context automation-ში მართლაც გადადის (ტესტით დადასტურდა)
- x_has_weekend (computed) sale.order-ზე ღილაკის invisible-სთვის
- View arch **v5**-ის კანონიკური ვერსია: `scripts/add-weekend-autofix.ps1`
- ტესტები: Sat 19.09→Mon 21.09 [purple], 0 weekend დარჩა ✓; ხელით შეცვლაზე purple მოეხსნა ✓
- ისტორია: მომხმარებელმა ჯერ აირჩია სრულად ხელით სწორება (ვარიანტი ა), მერე გადაწყვიტა
  ღილაკი + იასამნისფერი მონიშვნა (ვარიანტი ბ) — საბოლოო წესი ეს არის

## შაბ-კვ დაცვა + ინვოისების მთვლელი (დამატებულია 2026-08-27)

- **Send-ისა და Confirm-ის ბლოკი**: base.automation (id=21) sale.order-ის state-ზე —
  state ∈ ('sent','sale')-ზე გადასვლისას თუ გრაფიკში x_is_weekend სტრიქონია, UserError
  თარიღების ჩამონათვალით (rollback) — წითელი ხაზებით ვერც გაიგზავნება, ვერც დადასტურდება
- **ინვოისების გენერაციის ბლოკი**: იგივე შემოწმება ჩაემატა გენერაციის action-ში
- **Smart button** „განვ. ინვოისები" button_box-ში: x_installment_invoice_count (computed,
  search_count invoice_origin-ით) + server action (id=1041), რომელიც აბრუნებს act_window dict-ს
  ⚠️ server action-ს შეუძლია დააბრუნოს action — კოდში `action = {...}` მინიჭებით
- View arch **v4**-ის კანონიკური ვერსია: `scripts/add-weekend-guard-smartbutton.ps1`
  (ინვოისების action-ის კანონიკური კოდიც აქ არის)
- ტესტები: count=14 S01058-ზე ✓; შაბ-კვ თარიღებით გენერაცია და Confirm ორივე დაიბლოკა ✓

## შეთავაზების იმეილის შაბლონი (განახლებულია 2026-08-27)

- სტანდარტული `sale.email_template_edi_sale` (mail.template id=21) გადაიწერა ქართული ტექსტით:
  subject „კომერციული შეთავაზება № {{ object.name }}"; body-ში დინამიკურად ჩადგება ორდერის
  ნომერი, პირველი ხაზის პროდუქტის სახელი (t-out + filtered lambda), მენეჯერი და კომპანია
- დანართებში quotation PDF-ის გვერდით დაემატა „განვადების გრაფიკი" PDF (report_template_ids)
- Send ღილაკი ავტომატურად იყენებს; რენდერი გატესტილია compose wizard-ით S01058-ზე ✓
- ⚠️ Odoo 19-ში mail.template.generate_email აღარ არსებობს — რენდერის ტესტი compose wizard-ის
  default-ებით კეთდება (create context-ში default_template_id + read subject/body)
- სკრიპტი: `scripts/update-quotation-email.ps1`

## ინვოისების გენერაცია გრაფიკიდან (დამატებულია 2026-08-27)

- პროდუქტი „განვადების შენატანი" (INSTALLMENT-FEE, service, უგადასახადო)
- Server Action „FIGUREBI: ინვოისების გენერაცია" (id=1039): თითო გრაფიკის სტრიქონი →
  თითო **draft** out_invoice (due date = სტრიქონის თარიღი, invoice_origin = ორდერის ნომერი,
  payment term ცარიელი რომ due date არ გადაეწეროს); დუბლიკატის დაცვა invoice_origin-ით
- ღილაკი „ინვოისების გენერაცია" ტაბზე (confirm დიალოგით; ჩანს მხოლოდ გრაფიკის არსებობისას)
- შეზღუდვა: ინვოისები SO-ს invoice_status-ს არ ეხება (sale line-ებთან არაა მიბმული) —
  ბუღალტერი აპოსტებს Accounting-იდან; ნომერი მხოლოდ დაპოსტვისას ენიჭება
- View arch v3-ის კანონიკური ვერსია ამ სკრიპტშია: `scripts/add-invoice-generation.ps1`
- ტესტი: S01054 → 16 draft ინვოისი, ჯამი ზუსტად 64,391.51 ✓

## მოძველებული გრაფიკის გაფრთხილება (დამატებულია 2026-08-27)

- გენერაციისას Server Action ინახავს პარამეტრების ხელმოწერას `x_schedule_snapshot`-ში
  (ტიპი|%-ები|თარიღები|ინტერვალი|amount_total)
- computed `x_schedule_stale` ადარებს მიმდინარე ხელმოწერას snapshot-ს **და** გრაფიკის ჯამს
  amount_total-ს (>0.01 სხვაობა) — ნებისმიერი ცვლილება ააქტიურებს
- View-ში ყვითელი alert ტაბის თავში: „გრაფიკი მოძველებულია — თავიდან დააგენერირეთ"
- ხელით თარიღის შესწორება (შაბ-კვ ქეისი) გაფრთხილებას არ იწვევს; თანხის ხელით შეცვლა — იწვევს
- ⚠️ snapshot-ის ხელმოწერის ფორმატი ორ ადგილასაა და იდენტური უნდა დარჩეს: Server Action-ში და
  x_schedule_stale-ის compute-ში
- სკრიპტი: `scripts/add-stale-warning.ps1` (idempotent; აახლებს Server Action-საც და view-საც)
- ტესტი გავიდა: generate→false, %-ის ცვლილება→true, regenerate→false

## ფართის ავტომატური ჩასმა (დამატებულია 2026-08-27)

- `x_area` ველი product.template-ზე („ფართი (მ²)") — შევსებულია ხუთივე სატესტო ბინაზე
- **Automation Rule** „FIGUREBI: ფართის ავტომატური ჩასმა" (base.automation id=20) sale.order.line-ზე,
  trigger: product_id-ის ცვლილება → Quantity = x_area (Server Action „FIGUREBI: ფართი -> რაოდენობა")
- შეზღუდვა: Quantity ჩადგება ჩანაწერის **შენახვისას** (Save), აკრეფისთანავე არა — ცოცხალი
  onchange მხოლოდ Python-მოდულით შეიძლება (git სჭირდება)
- სკრიპტი: `scripts/add-area-autofill.ps1` (idempotent); ტესტი გავიდა: პროდუქტის არჩევა →
  qty=52.1, subtotal=67,780.54 ავტომატურად

## Data-მოდული Import Module-თვის (2026-09-01)

მომხმარებელს on-premise სერვერზე ფაილური წვდომა არ აქვს და Apps → **Import Module**
ღილაკით ატვირთვა უნდა — ამისთვის აეწყო **`addons/figurebi_installment_data/`** +
**`figurebi_installment_data.zip`** (პროექტის ფესვში): Python-ის გარეშე, მხოლოდ
XML/CSV ჩანაწერები (Studio-ს ექსპორტის სტილში), რომ Import Module-მა მიიღოს.

- შიგთავსი: manual მოდელი/ველები (computed-ებით CDATA-კოდით), defaults (ir.default
  json_value-თი), 4 ღილაკის server action, 10 automation (სინქრონები, დაცვები, area,
  CRM), view arch v13 (`%(xmlid)d` ღილაკებით), PDF report, email-შაბლონის override,
  INSTALLMENT-FEE პროდუქტი, access CSV
- **CRM მენეჯერები აქ System Parameters-ით ინიშნება** (Settings → Technical → System
  Parameters): `figurebi.en_manager_id` და `figurebi.ka_manager_id` = user ID-ები
  (data-მოდულს Settings-გვერდი ვერ ექნება Python-ის გარეშე)
- ქცევა staging-ის იდენტურია (გადათვლები Save-ზე); scss/ცოცხალი onchange არ შედის
- ⚠️ **არ დააინსტალიროთ ბაზაზე, სადაც manual x_ ველები უკვე დგას** (communapp staging!) —
  დაეჯახება; მხოლოდ სუფთა ბაზისთვისაა
- ⚠️ ჯერ არსად გატესტილა — პირველი იმპორტის შეცდომის ტექსტი მჭირდება გასასწორებლად

## სრული მოდული v2 (შეიფუთა 2026-09-01, მომხმარებლის მოთხოვნით)

`addons/figurebi_installment/` **სრულად განახლდა** — ყველა ფუნქციონალი, რაც staging-ზე manual
მექანიზმებით აეწყო, ახლა ინსტალირებადი Odoo 19 მოდულია; zip: **`figurebi_installment.zip`**
(პროექტის ფესვში, ატვირთვისთვის მზად).

- ველების/მოდელის სახელები **ზუსტად ემთხვევა** staging-ის manual (x_) სახელებს — view/PDF/დოკები იდენტურია
- **Python-უპირატესობა**: $↔%, ფასდაკლების სამმხრივი სინქრონი, ფართის ჩასმა და ბოლო თარიღის
  სინქრონი **onchange-ებით ცოცხლადაა** (Save-ის ლოდინი აღარაა); write()-გუშაგები RPC-სთვისაც რჩება
- შემადგენლობა: sale_order.py (გენერაცია v5 + bank split + ყველა ვალიდაცია + snapshot/stale +
  weekend guard write()-ში + ინვოისები + smart button), installment_line.py (balance, weekend,
  purple + ხელით შესწორებაზე purple-ის მოხსნა), product_template.py (x_area),
  sale_order_line.py (area→qty onchange), crm_lead.py (ენით განაწილება — მენეჯერები
  **Settings-შია კონფიგურირებადი**: figurebi.en/ka_manager_id ir.config_parameter),
  res_config_settings (FIGUREBI განყოფილება), report/ (PDF), data/ (INSTALLMENT-FEE პროდუქტი
  xmlid-ით `product_installment_fee`; ქართული email-შაბლონის override), scss (purple/red რიგები),
  security csv
- **ინსტალაცია**: Odoo.sh → git repo-ში ჩადება + staging branch; on-premise → addons path.
  ⚠️ Odoo Online (SaaS) პორტალზე custom Python მოდულის ატვირთვა შეუძლებელია — იქ მხოლოდ
  ჩვენი manual/RPC მიდგომა მუშაობს (რაც communapp staging-ზეა)
- ⚠️ მოდულის დაყენება იმ ბაზაზე, სადაც manual x_ ველები უკვე არსებობს, დაეჯახება
  (ir.model.fields unique) — ჯერ manual ველები უნდა წაიშალოს
- მოდული ჯერ არცერთ სერვერზე არ არის რეალურად დაინსტალირებული/გატესტილი (git არ გვაქვს) —
  პირველი ინსტალაციისას შესაძლოა წვრილმანი ხარვეზები გამოჩნდეს (მაგ. view xpath-ები)

## ტესტის შედეგები

houseltd-ზე (წაშლამდე, 2026-08-27) ოთხივე შემთხვევა გავიდა Excel-ის მაგალითზე:
- Excel-ის მაგალითი: 7,000 + 4×1,750 + 56,000 = 70,000 ✓; შაბათი მოინიშნა ✓; PMT = 869.49 (Excel: 869.492) ✓
- 20%+80% balloon-ის გარეშე ✓; ერთიანი გადახდა ✓; ბანკის სესხი ✓

communapp-ზე (მიმდინარე staging, 2026-08-27):
- Demo SO **S01054**: ბინა APAR/I/512, 52.1 მ² × 1300.97 − 5% = 64,391.51 →
  6,439.15 (ტრანში) + 14×459.94 + 51,513.20 (ნაშთი 2027-12-15, იჭრება 15 რიცხვზე) ✓
  weekend-სტრიქონები მოინიშნა (2026-11-15, 2027-05-15, 2027-08-15) ✓

## დეპლოი on-premise სერვერზე (შესრულებულია 2026-09-02) ✅

**პროდაქშენ სერვერი**: https://46.233.53.183:2223/ (Odoo 19.0+e Enterprise, DB `odoo`,
proxy_mode, self-signed cert — RPC-სთვის cert-შემოწმება გამორთეთ).
ლოგინი: dchachkhuna@gmail.com (uid=2); RPC-სთვის API key მუშაობს პაროლად.
SSH: oddo@192.168.100.71 (LAN; პორტი 22; sudo აქვს; **odoo/enterprise საქაღალდეები
oddo-თი წაუკითხავია — ყველაფერს sudo სჭირდება**). plink/pscp-ით ვმუშაობთ
(⚠️ pscp ქართულ გზას ვერ იღებს — ჯერ ASCII გზაზე დააკოპირეთ).

- **Odoo layout**: `/opt/odoo/odoo-19` (venv შიგნით), addons: `/opt/odoo/custom-addons`
  (აქ დგას მოდული + სხვისი `vertikali`), enterprise: `/opt/odoo/enterprise`;
  კონფიგი `/etc/odoo/odoo.conf` (http_port 8069, ლოგი `/var/log/odoo/odoo.log`);
  სერვისი `systemctl restart odoo`; ფაილების owner `odoo:odoo` უნდა იყოს (chown -R!)
- **მოდული `figurebi_installment` დაინსტალირდა და გატესტილია** (პირველი რეალური ინსტალაცია):
  Excel-ქეისი 70,000/10%+80% → 7,000 + 5×1,400 + 56,000 (15.12), ჯამი ზუსტი, PMT 869.49 ✓;
  weekend მოინიშნა და autofix-მა შაბ 10.10→ორშ 12.10 [purple] ✓; Confirm წითლებზე დაიბლოკა ✓;
  ინვოისები draft-ზე დაიბლოკა, Confirm-ის მერე 7 draft ინვოისი ჯამით 70,000 ✓;
  PDF დარენდერდა ✓; backend იტვირთება ✓. სატესტო ჩანაწერები წაშლილია/დაარქივებულია.
- **გასწორდა ინსტალაციისას**: sale_order.py:434 — ქართული ციტატის დამხურავი ASCII `"`
  სტრიქონს ჭრიდა (SyntaxError U+2014); შეიცვალა `“`-თი. ლოკალური წყარო და zip განახლდა.
- **`figurebi_installment.zip` ხელახლა შეიკრა Linux-ზე** — ძველი Windows-ის backslash
  entry-გზებით იყო და unzip-ზე გაფუჭდებოდა (⚠️ Compress-Archive-ს ნუ გამოიყენებთ zip-ისთვის)
- ინსტალაციის გზა: pscp → /home/oddo → sudo cp → chown odoo:odoo → systemctl restart odoo →
  RPC: ir.module.module.update_list() + button_immediate_install
- ⚠️ **ღია საკითხები ახალ სერვერზე**: (1) CRM მენეჯერების ID-ები Settings-ში (FIGUREBI
  განყოფილება) ჯერ არაა მითითებული — ლიდების ენით განაწილება ვერ იმუშავებს კონფიგამდე;
  (2) $↔% და ფასდაკლების სინქრონები **მხოლოდ onchange-ებია** (UI-ში ცოცხლად მუშაობს;
  RPC-თ create/write-ზე არ ეშვება — CLAUDE.md-ის ძველი ჩანაწერი write-გუშაგებზე მცდარი იყო);
  (3) კომპანიის ლოგო/რეკვიზიტები Settings-ში ასატვირთია PDF-ისთვის; (4) სატესტო
  პროდუქტები/კლიენტები ამ ბაზაზე არ შექმნილა — რეალური ობიექტების იმპორტი ცალკე ამოცანაა
- მომხმარებლის რეფერენსი (2026-09-02): github.com/dlabadze/community (branch com_staging) —
  პრივატულია, API-თ ვერ წავიკითხეთ; ინსტალაცია მის გარეშე დასრულდა სტანდარტული გზით

## ფასნამატის ფიქსი + საბოლოო ფასის უკუგადათვლა (2026-09-02, v19.0.2.1.0)

- **ბაგი**: ახალ სერვერზე ფასდაკლება/ფასნამატი ხაზამდე ვერ აღწევდა (pct ორდერზე ინახებოდა,
  line.discount=0 რჩებოდა). მიზეზი: `sale.group_discount_per_so_line` ჩართული არ იყო →
  Disc.% სვეტი ხაზების ვიუში არაა → onchange-ის მინიჭება ხაზზე client-ში იკარგება.
  **გასწორდა სტანდარტულად**: res.config.settings→group_discount_per_so_line=true (RPC-თ).
  ⚠️ ახალ ბაზაზე ეს setting ინსტალაციის აუცილებელი წინაპირობაა!
- **ახალი ფუნქცია (მომხმარებლის მოთხოვნა)**: „საბოლოო ფასი ($)" და „საბოლოო კვ.მ ფასი"
  ბარათები **ჩაწერადია** — შეყვანისას pct უკუიანგარიშება ((1−საბოლოო/საწყისი)×100) და
  ყველა ფასდაკლების ველი + ხაზის Disc.% სინქრონდება. ორივე მიმართულება მუშაობს
  (215,712→-7% ფასნამატი; 191,520→5% ფასდაკლება ✓)
- იმპლემენტაცია: `x_final_total` (ახალი ველი) და `x_final_price_per_m2` — ორივე
  compute+inverse+store=True+readonly=False, **ცალ-ცალკე compute-მეთოდებით**
  (⚠️ საერთო compute-მეთოდი ორივეს „protect"-ავს ერთის ჩაწერისას და მეორე მოძველებული
  რჩება — ამიტომ გაიყო) + ცოცხალი onchange-ები UI-სთვის; საერთო helper
  `_set_discount_from_pct`. ვიუში „საბოლოო ფასი" ბარათი amount_total→x_final_total შეიცვალა,
  final_m2-ს readonly მოეხსნა. inverse-ების წყალობით RPC-თაც მუშაობს (ტესტი გავიდა)
- S00023 (მომხმარებლის საცდელი ორდერი): ძველი არათანმიმდევრული მდგომარეობა დარჩა
  (pct=-5, ხაზი 0%) — %-ის ხელახლა შეყვანა საკმარისია

## ფასდაკლების % ზუსტი სიზუსტით (2026-09-03, v19.0.2.1.2)

- **ბაგი (მომხმარებლის რეპორტი)**: 10.7896%-ის შეყვანისას 10.79-ით ითვლიდა. სამი მიზეზი:
  (1) `x_discount_pct`-ს digits არ ჰქონდა → კლიენტი შეყვანას 2 ათწილადზე ჭრიდა;
  (2) Odoo-ს Decimal Accuracy „Discount"=2 → ხაზის discount 2-ზე მრგვალდებოდა;
  (3) `_figurebi_pct_from_final_total` და `_onchange_final_price_per_m2` pct-ს `round(...,2)`-ით
  ითვლიდნენ (სხვა გზები 4-ით — ასიმეტრია სწორედ ამან გამოააშკარავა)
- **ფიქსი**: `x_discount_pct` digits=(16,4) — ბარათი 4 ათწილადს იღებს/აჩვენებს (დამრგვალებული
  ჩვენება, როგორც მომხმარებელმა ითხოვა); Decimal Accuracy **Discount=6** (ხაზზე ზუსტი პროცენტი);
  ყველა დერივაცია `round(...,6)` → საბოლოო ჯამი თეთრამდე ზუსტია
- **გუშაგები გადავიდა თანხის სივრცეში**: ძველი `abs(pct_new−pct_cur)<0.005` წვრილ ცვლილებებს
  ყლაპავდა; ახლა `_figurebi_final_total_reached()` / per-m2 achieved-შემოწმება — გამოტოვება
  მხოლოდ მაშინ, როცა შეყვანილი თანხა უკვე მიღწეულია ±0.011-ში (knock-on damping შენარჩუნებულია)
- ტესტები: final_total=195,192.36 → ხაზი 10.789598%, ჯამი ზუსტად 195,192.36, ბარათი 10.7896 ✓;
  200,000 → ზუსტად 200,000 ✓; idempotent ✓; -7%/5% რეგრესია ✓
- ⚠️ ახალ ბაზაზე კონფიგ-წინაპირობა: Decimal Accuracy „Discount" = **6** (developer mode →
  Technical → Decimal Accuracy) — მოდული ამას თავად არ აყენებს
- ⚠️ დაკვირვება: ლოკალური sale_order.py უფრო განვითარებულია, ვიდრე ადრინდელი ჩანაწერები
  აღწერს (tax-aware `_figurebi_gross_incl_tax`, area-aware `_figurebi_unit_area`/price_per_m2,
  vertikali-ს vk_area_total-ის fallback) — წყაროა ჭეშმარიტება, ძველი სექციები კი ისტორია

## 4 ათწილადი ყველგან — % და $ (2026-09-03, v19.0.2.2.0, მომხმარებლის მოთხოვნით)

- კალკულატორის ყველა % და $ ველს მიეცა `digits=(16,4)` (ჩვენება+შეყვანა 4 ათწილადით):
  ტრანში %/$, ბოლო %/$, ფასდაკლების %/კვ.მ$/სრული$, გრაფიკით %/$, საწყისი კვ.მ/ჯამური,
  საბოლოო კვ.მ/ჯამური; sync-გამოთვლების round(...,2)-ები → round(...,4)
- **2-ზე დარჩა** (რეალური ფულია): გრაფიკის სტრიქონები/გენერაცია, ინვოისები, სესხის თანხა,
  PMT, amount_total (currency), snapshot-ის ხელმოწერა (ფორმატი უცვლელი!)
- ტესტი: pct 0.8055 / amount 1762.4340 უცვლელად ინახება; final 195,192.36 → ჯამი ზუსტად ✓
- x_bank_rate განზრახ არ შეხებია (14.0000 ჩვენება არასასურველი იქნებოდა; მოთხოვნისას მარტივია)

## VAT-ის მოხსნა ბინებზე — Excel-პარიტეტი (2026-09-03, data-ფიქსი სერვერზე)

- **პრობლემა**: „საბოლოო ფასი" Excel-ს არ ემთხვეოდა (-5%-ზე 264,201 ≠ 229,740) — ბინის
  პროდუქტებს დეფოლტი **15% გადასახადი** ჰქონდათ და amount_total (→x_final_total) tax-იანი იყო;
  ფასდაკლების ბარათები კი უგადასახადო ბაზაზეა (ამიტომ ისინი ემთხვეოდა). Excel VAT-ს არ იცნობს.
- **ფიქსი (data, კოდი უცვლელი)**: taxes_id გასუფთავდა **126 Apartment-პროდუქტზე** და 14
  draft/sent ორდერ-ხაზზე (S00004…S00044). ტესტი: A-0204, final=229,740 → pct=-5, total ზუსტი ✓
- **დახურულია (2026-09-03, მომხმარებლის ხელით)**: მომხმარებელმა თავად ჩაუწერა 0 გადასახადის
  ჩანაწერს — account.tax id=1 ახლა „0%"/amount=0-ია (იყო „15%"). ახალი პროდუქტები ისევ ამ
  ჩანაწერს იღებენ default-ად, მაგრამ ის 0-ს ითვლის → ჯამები აღარ იბერება. გადამოწმებულია
  სატესტო პროდუქტით ✓. ⚠️ თუ ოდესმე რეალური დღგ დასჭირდათ, ეს ჩანაწერი 15-ზე უნდა დაბრუნდეს
- შენიშვნა: Excel-ის 229,739.82 vs ჩვენი 229,740.00 — 18 თეთრი საწყისი ფასიდანვეა
  (Excel: 3,180.23×68.8=218,799.82; ბაზაში პროდუქტის ფასი მრგვალი 218,800-ია), გამოთვლა იდენტურია

## ბალონის თვის წესი (2026-09-03/04, v19.0.2.3.0, მომხმარებლის მოთხოვნით)

- **წესი**: თუ გრაფიკის ბოლო შენატანი ბალონის (ბოლო გადახდის) თვეშივე ხვდება, ის შენატანი
  აღარ გენერირდება — დარჩენილები იზრდება, რომ schedule-თანხა სრულად დაფაროს (ბოლო თვეში
  კლიენტი ორჯერ არ იხდის). იმპლემენტაცია: `_installment_vals`-ში dates.pop() balloon-თვის
  დამთხვევაზე, ძველი „bdate > dates[-1]" ვალიდაციამდე
- ტესტი: 201,600 / ტრანში 20,160 (03.09) / ბალონი 161,280 (07.01.27) / დაწყება 05.10, ვადა 4 →
  4×5,040-ის ნაცვლად **3×6,720** (ოქტ/ნოე/დეკ 5) + ბალონი; სულ 5 სტრიქონი, ჯამი ზუსტი ✓
- ⚠️ **დეპლოის ინციდენტი**: პირველი ცდისას SSH (LAN) გაწყდა — pscp/plink ჩავარდა, RPC-upgrade
  კი ძველ კოდზე გაეშვა („UPGRADE OK" მოტყუებაა თუ ფაილი არ ასულა!); მეორე ცდაზე remote sh-ში
  ესკეიპულმა `\"` -მა მთელი ჯაჭვი ჩააგდო (cp/restart არ შესრულდა). **წესი: ყოველი დეპლოის
  ბოლოს გადაამოწმე latest_version RPC-თ** (ახლა ასეც გაკეთდა → 19.0.2.3.0 ✓)
- 💡 SSH საჯარო IP-ზეც არსებობს: **46.233.53.183:2222** (LAN-ის მიუწვდომლობისას გამოსადეგი)

## შემდეგი ნაბიჯები (2026-09-02 სესიის ბოლოს)

1. **CRM მენეჯერები** ახალ სერვერზე: Settings → CRM → FIGUREBI — რეალური მენეჯერების არჩევა
   (მანამდე ლიდების ენით განაწილება არ მუშაობს)
2. **კომპანიის ლოგო/რეკვიზიტები** Settings-ში — PDF-სა და იმეილში გამოსაჩენად
3. **რეალური ობიექტების (ბინების) იმპორტი** — პროდუქტების ბაზა მ² ერთეულით, ფასით და
   x_area ველით (ცალკე ამოცანა; communapp-ის add-test-data.ps1 ნიმუშად გამოდგება)
4. მომხმარებელმა S00023-ზე ხელახლა შეიყვანოს ფასნამატი — ძველი ცდის კვალი (pct=-5, ხაზი 0%)
   თავად გაქრება
5. ღია საკითხი (ძველი): საბანკო ჯგუფი მხოლოდ bank_loan-ზე დავმალოთ თუ არა — პასუხი არ მოსულა
6. სურვილისამებრ: პროექტის git-რეპოდ ინიციალიზაცია ვერსიების ისტორიისთვის — მაგრამ ჯერ
   creds/API-გასაღებები უნდა გავიდეს ფაილებიდან .env-ში (CLAUDE.md და სკრიპტები პაროლებს შეიცავს)
7. მომდევნო ეტაპები გეგმიდან: ობიექტების ბაზის იმპორტი, ჯავშნები (3-დღიანი ფასის დაფიქსირება)

## სატესტო მონაცემები communapp-ზე

- პროდუქტები (uom = მ², ფასი = კვ.მ ფასი): APAR/I/512 (52.1მ², 1300.97), APAR/I/513 (45.3მ², 1350),
  APAR/I/812 (68.4მ², 1250), APAR/II/101 (75მ², 1400), COM/I/1 (120მ², 1800)
- კლიენტები: „გიორგი მაისურაძე (ტესტი)", „ნინო კაპანაძე (ტესტი)"
- ჩართულია Disc.% სვეტი ხაზებზე (group_discount_per_so_line)

---

# Project quick reference (docs-init, 2026-09-03)

## Stack
- Odoo 19.0+e Enterprise, on-premise (Ubuntu VM, PostgreSQL 16, venv Python at `/opt/odoo/odoo-19/venv`)
- Parallel demo: Odoo.sh staging (communapp) built with manual x_ records via JSON-RPC (no module)
- No local dev instance — changes are deployed straight to the on-prem server over SSH/RPC
- Secrets (server URLs with credentials, API keys, SSH): `SECRETS.local.md` (git-ignored)

## Commands (the ones that actually work here)
- Upload a changed file (ASCII temp path first — pscp breaks on the Georgian project path):
  `pscp -pw <ssh-pwd> <local> oddo@192.168.100.71:/home/oddo/figurebi_installment/...`
- Install into addons + restart:
  `plink oddo@192.168.100.71 "echo <ssh-pwd> | sudo -S sh -c 'cp -r /home/oddo/figurebi_installment /opt/odoo/custom-addons/ && chown -R odoo:odoo /opt/odoo/custom-addons/figurebi_installment && systemctl restart odoo'"`
- Upgrade module: JSON-RPC `ir.module.module.button_immediate_upgrade [[1449]]` (db `odoo`, uid 2, API key as password)
- Logs: `plink ... "echo <ssh-pwd> | sudo -S tail -50 /var/log/odoo/odoo.log"`
- Odoo shell (debugging): `sudo -u odoo /opt/odoo/odoo-19/venv/bin/python /opt/odoo/odoo-19/odoo-bin shell -c /etc/odoo/odoo.conf -d odoo --no-http < script.py`
- Tests: none automated — user tests functionally in the UI after each deploy

## Layout
- `addons/figurebi_installment/` — the real Odoo 19 Python module (single source of truth)
- `addons/figurebi_installment_data/` — XML/CSV-only twin for SaaS Import Module (untested)
- `scripts/` — historical JSON-RPC deploy/test scripts for the staging demo
- `docs/` — PRD, SPEC, PLAN, ARCHITECTURE, DECISIONS
- `research/` — source Excel calculator

## Conventions
- Field prefix `x_` on inherited models (parity with the manual staging records — do not rename)
- Custom model: `x_figurebi_installment_line`; config params: `figurebi.*`; context guards: `figurebi_*`
- XML ids: snake_case, module-prefixed on reference (`figurebi_installment.view_order_form_installment`)
- Georgian strings in field labels/UI, English code comments; PS1 files saved UTF-8 **with BOM**
- Commits: conventional (`feat|fix|docs|chore(scope): ...`)

## Rules (MUST / NEVER)
- NEVER edit core/enterprise addons — always `_inherit`
- ALWAYS keep `security/ir.model.access.csv` rows for any new model
- ALWAYS bump `__manifest__.py` version on functional change and upgrade the module on the server
- ALWAYS rebuild `figurebi_installment.zip` on Linux (Windows zips carry backslash paths)
- NEVER commit credentials/API keys — they live only in `SECRETS.local.md`
- NEVER install the module on a DB that already has the manual x_ fields (unique constraint clash)
- Snapshot signature is duplicated (action + stale compute) — keep both identical
- Server prerequisites on a fresh DB: Discounts group ON, Decimal Accuracy „Discount" = 6

## Workflow
PRD → SPEC → PLAN (approved by the user before code) → code → deploy → user functional test → `/docs-sync`.
One task at a time; standard Odoo solution checked before custom code (standard-first).

## Git
- Remote `origin`: https://github.com/refreshg/fmg_flats_figurebi.git (company repo; vertikali lives on `main`)
- Our work: branch **`figurebi`** (local = remote name) — NEVER push to `main`
- Routine: `git pull` BEFORE starting work → commit → `git push` (plain commands work;
  credential.helper=wincred is set in repo config, PAT backup in SECRETS.local.md)
- ⚠️ repo is currently public — no secrets in tracked files, ever

## Docs map
- `docs/PRD.md` — what/for whom (Georgian, user-facing)
- `docs/SPEC.md` — data model, logic, views, security (English)
- `docs/PLAN.md` — next milestones as checkboxes; needs user approval
- `docs/ARCHITECTURE.md` — components and data flow
- `docs/DECISIONS.md` — ADRs
- `addons/figurebi_installment/README.md` — install/config for admins
- `INSTALL_ON_PREMISE.md` — step-by-step server install (Georgian)
