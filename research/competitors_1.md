# კონკურენტების კვლევა: ინტერაქტიული ობიექტის/კორპუსის/სართულის/ბინის ამომრჩევი პლატფორმები

**თარიღი:** 2026-08-21
**სკოუპი:** პროდუქტები, რომლებიც დეველოპერს აძლევს ვიზუალურ flow-ს — გენგეგმა → კორპუსი → სართული → ბინა → ბინის ბარათი (ფასი, სტატუსი, გეგმა, 3D/ტური) + ინტეგრაციები.
**მეთოდი:** თითოეული საიტი გადამოწმდა უშუალოდ (homepage, product/pricing/docs გვერდები, live demo-ები). Hero copy მოცემულია verbatim.

---

## TL;DR — შედარებითი ცხრილი

| # | პროდუქტი | ქვეყანა | მოდელი | გენგეგმა→კორპუსი→სართული→ბინა | 3D | CRM | ფასი |
|---|---|---|---|---|---|---|---|
| 1 | [Flat.show](https://www.flatshow.org/) | 🇺🇦 უკრაინა | custom build + widget | ✅ სრული flow, 3D რენდერებზე | ✅ რენდერი + 360° | ✅ ნებისმიერი CRM/ERP | quote |
| 2 | [3D Flat Finder](https://www.3dflatfinder.com/) | 🇭🇺 უნგრეთი | SaaS | ✅ 3D მოდელზე + floorplan selector | ✅ ნამდვილი 3D, მზის სიმულაცია | ✅ Salesforce, HubSpot, Realpad, Sheets, webhooks | €199–399/თვე + €900 setup |
| 3 | [Your Next Home](https://www.yournexthome.app/) | 🇵🇱 პოლონეთი | SaaS | ✅ 360° orbit → კორპუსი → ბინა (ფასადზე highlight) | ✅ ნამდვილი 3D | ✅ Salesforce, HubSpot + built-in CRM, API | $400/თვე/პროექტი |
| 4 | [Vinode](https://vinode.io/) | 🇵🇱 პოლონეთი | build + subscription | ✅ ქალაქის მასშტაბიდან ბინის ინტერიერამდე | ✅ Unreal, pre-rendered streaming | ✅ built-in + HubSpot, Odoo, Pipedrive | quote (build + per-unit + sub) |
| 5 | [3D Twin (3D Estate)](https://www.3dtwin.com/) | 🇵🇱 პოლონეთი | tiered packages | ✅ მბრუნავი 3D მოდელი → ბინა | ✅ Unreal, ბალკონის ხედები | ✅ two-way, ნებისმიერი სისტემა | quote |
| 6 | [GRIDIX](https://gridix.live/) | 🌍 RU-speaking, intl | SaaS | ✅ Master plan+ → შახმატკა → გეგმა (2D) | ❌ (2D) | ✅ amoCRM, Bitrix24 + built-in | $299–599/თვე/პროექტი |
| 7 | [Flatter](https://www.flatter.hu/en) | 🇭🇺 უნგრეთი | hosted SaaS | ✅ site plan → building → სართულების ბარათები | ✅ 3D site view + რენდერები | ❌ (email only) | quote |
| 8 | [Realty.cat](https://realty.cat/) | 🇷🇺 რუსეთი | SaaS | ✅ გენგეგმა → შახმატკა → სართულის გეგმა (2D) | ❌ (2D) | ✅ Bitrix24 | 17 500 ₽/თვე-დან |
| ref | [Profitbase](https://profitbase.ru/) | 🇷🇺 | SaaS ecosystem | ✅ 8 ხედი (გენგეგმა, ფასადი, სართული, შახმატკა…) | 3D ტურები პარტნიორებით | ✅ amoCRM, Bitrix24, SberCRM | 20 700 ₽/თვე |
| ref | [Flatris](https://flatris.com.ua/en/) | 🇺🇦 | SaaS | ✅ 2D პოლიგონები: ობიექტი → კორპუსი → სექცია → სართული | ❌ (სტატიკური 3D სურათი) | ✅ Kommo, Pipedrive, Bitrix24, Sheets | tiers by unit count |

---

## 1. Flat.show (FLAT.SHOW Inc.)

- **URL:** https://www.flatshow.org/ (ძველი RU landing: https://flat.show/landing/index.html)
- **ქვეყანა:** უკრაინა (კიევი), დაარსდა 2015; 150+ ინტერაქტიული ინსტრუმენტი, 40+ კლიენტი, >4 მლნ მ²
- **Live demo-ები:** https://rybalsky.com.ua/en/3d/#/ · https://re-triiinity.com.ua/en/choice-plan#/ · https://kamerton.house/apartments/

### Hero copy
- **EN (flatshow.org):** "Show Real Estate online" — "Make a digital form of your real estate project with our tools. Differentiate it in the online universe."
- **RU (flat.show):** «Интерактивный модуль выбора недвижимости» — «Легко устанавливается на любой сайт. Полноценный раздел выбора квартир на вашем сайте. Дайте вашим покупателям удобный выбор квартиры, офиса или торговой площади!»
- 3-ნაბიჯიანი pitch: **VISUALISE → INTERACTIFY → INTEGRATE** ("Integrate a 3D widget into website and CRM system. Build your own marketing and sales ecosystem.")

### Sitemap
Home `/` · Portfolio `/portfolio` · Services `/services` · About `/about` · Contact `/contact` · Schedule a meeting `/schedule-a-meeting` · Work: `/work/diadans`, `/work/rybalsky`, `/work/triiinity`, `/work/edeldorf-hills`, `/work/home-batumi`

### Features
- Embeddable მოდული — "easily installed on any website", responsive (მობილური/ტაბლეტი/დესკტოპი)
- სრული flow: კომპლექსი/გენგეგმა → კორპუსი → სართული → ბინა; მომხმარებელი დამოუკიდებლად ირჩევს
- ერთეულის ტიპები: ბინები, ოფისები, კომერცია, პარკინგი, სათავსოები
- ფილტრაცია ფართობით და გეგმარებით
- ფოტორეალისტური 3D რენდერები, 360° პანორამები (ექსტერიერი/ინტერიერი), ფანჯრიდან ხედი, Interior Web Tours
- Turnkey დიზაინი კლიენტის ბრენდინგის ქვეშ
- ორმაგი გამოყენება: საიტის ვიჯეტი + გაყიდვების ოფისის დიდი ეკრანი
- CRM/ERP ინტეგრაცია (ფასი/ხელმისაწვდომობა)
- მიწოდების ვადა ~5 კვირა/პროექტი
- **ფასი:** quote ("estimate within 72 hours")
- **კლიენტები:** ENSO (Diadans, 552 ბინა), SAGA Development (Rybalsky, 1000+), Triiinity (411), Edeldorf Hills, Home Batumi (საქართველო)

---

## 2. 3D Flat Finder (3D Flat Finder Zrt.)

- **URL:** https://www.3dflatfinder.com/
- **ქვეყანა:** უნგრეთი (ბუდაპეშტი); 100+ development, live viewers `*.property-sales-engine.com` (მაგ. https://woodland.property-sales-engine.com/en)

### Hero copy
"The 3D Sales Platform for Premium Developers" — "Spark desire | Sharpen understanding | Speed up sales"

### Sitemap
Features `/features.html` · Is it for you? `/solutions.html` · References `/references.html` · How It Works `/how-it-works.html` · Pricing `/pricing.html` · About `/about.html` · Book a Demo `/contact.html` · FAQ `/faq.html` · Privacy / Cookies / Terms & Imprint

### Features
- იერარქია: masterplan → building → home → view & surroundings; Multi-building system (ფაზები ერთ ხედში)
- **AreaView 360** — ინტერაქტიული აეროხედი სკოლებით, პარკებით, ტრანსპორტით
- **Virtual Walk** — ქუჩის დონის ტური დასრულებულ შენობასთან
- **Orientation Compass** + **Sunlight Simulation** — კორპუსის ბრუნვა, დღის დროების გადართვა
- **Spatial filtering** — ფილტრი პირდაპირ 3D მოდელზე (სართული, ფართი, ორიენტაცია, ხედი, ფასი)
- **UnitView selector** — ბინის არჩევა 3D კორპუსზე; hover → ძირითადი დეტალები
- **Floorplan Selector** — სართულის გეგმაზე გადართვა და ბინების დათვალიერება დონეების მიხედვით
- **3D Dollhouse** — ბინის ჭრილი 3D მოდელი; **Balcony Preview / Balcony Sunlight** — თითო ბალკონის ხედი
- **HomeView Tour** — ინტერიერის walkthrough სხვადასხვა სტილით
- Download brochure (PDF თითო ბინაზე), List & Card View, Smart Flat Comparison, Favourites & shortlist (გაზიარება ოჯახთან/აგენტთან)
- **Live CRM Sync** — ორმხრივი; central inventory (custom fields, statuses, pricing)
- Lead capture ბინის კონტექსტით (shortlist depth, comparisons, revisits → CRM push)
- Analytics — event-level data layer, რომელი კორპუსი/სართული/ფასის დიაპაზონი იზიდავს ყურადღებას
- ინტეგრაციები: Salesforce, HubSpot, WordPress, Google Sheets, Realpad, webhooks; custom integrations უფასოდ
- Embed ერთი ხაზით (iframe), white-label, custom domain, SEO-ready, multilanguage, touchscreen
- **ფასი:** Creator Workspace — უფასო; Standalone €199/თვე + €900 setup; Connected €399/თვე + €900 setup (two-way CRM, webhooks); Custom — enterprise; −20% წლიური
- **კლიენტები:** Cordia, Futureal, Metrodom, Bayer Construct, Atenor, CPI Property Group, KÉSZ, OTP Ingatlanpont და სხვ.

---

## 3. Your Next Home (by Digital Bunch)

- **URL:** https://www.yournexthome.app/
- **ქვეყანა:** პოლონეთი (გუნდი: სიდნეი, ტორონტო, პოლონეთი)

### Hero copy
"Build your property viewer to close sales faster" — "Give buyers a clear, always-current view of your entire inventory in interactive 3D — and give yourself one connected platform that shows exactly what's selling, when, and to whom."

### Sitemap
Features `/features` (sub: `/features/360-building-model`, `/features/integrations`…) · Solutions (By goal / By role / By property type) · Pricing · Production services · Contact · Changelog · Developers · Log in `/login` · Privacy / Terms / Company details

### Features
- **360° building model:** "Start above the whole development and orbit every building together" → "Select a building to open an orbit around that one on its own" → "every apartment on it becomes selectable, right down to a single home"
- Hover ბინაზე → ფასადზე highlight ("shows exactly which windows and which part of the facade belong to it"); სტატუსი იკითხება პირდაპირ კორპუსიდან
- ბინის ბარათი: live availability, price, floor plan, tour; reprice/reserve → მყისიერად ჩანს
- Interactive 3D floor plans, Virtual walkthrough & style switching, 360° ტურები, Amenity hotspots, 360° compass, Media gallery თითო ბინაზე, Interactive map
- Floorplan selector (coming soon), Spec sheets, Apartment comparison, Favourites & sharing, Filters, AI help assistant
- Inventory management, Built-in CRM (enquiries, attribution, lead routing), Lead scoring, Engagement analytics, Project summaries
- Branded viewers, Custom domain & UI, Embed anywhere, SEO tags, public API
- ინტეგრაციები: Salesforce, Onyx, voxDeveloper, HubSpot; custom ინტეგრაცია ~1 კვირაში უფასოდ
- მოწყობილობები: ტელეფონი, ტაბლეტი, PC, TV & touchscreens
- **ფასი:** ერთი გეგმა — $400/თვე/პროექტი ან $4,800/წელი; setup fee არ არის; "12 units or 200 — same price"
- **კლიენტები:** Diriyah Villas (KSA), DeWAG (მიუნხენი), Hamilton Grove (ბრისბენი), Kevl (ტორონტო), Palatium (პოლონეთი), Onyx Resort

---

## 4. Vinode (by Prographers)

- **URL:** https://vinode.io/ (პროექტები: https://vinode.io/projects)
- **ქვეყანა:** პოლონეთი

### Hero copy
"Create, Show, Sell" — "Build Real Estate websites and track sales in CRM"

### Sitemap
about `/#about` · pricing `/#pricing` · projects `/projects` · answers `/answers` · Blog `/blog` · contact `/contact` · პროექტის გვერდები `/projects/{slug}` (safa-almukaymen, stgallen, river-residence, kownatki…)

### Features
- "a single 3D model of an entire development… from an aerial view of the whole site down into one unit's interior"; მასშტაბი — ქალაქის masterplan (Safa Almukaymen: 14 კორპუსი / 535 ბინა)
- St. Gallen flow: "pick a building first, then explore its floors and individual apartments from a single interactive 3D model"
- ფოტორეალისტური Unreal Engine; pre-rendered და video-streamed (არ ტვირთავს მომხმარებლის მოწყობილობას); pixel streaming kiosk-ისთვის
- 3D floor plans, PDF გეგმები, Virtual Tours (3D floor plan + room-by-room + 360°), ინტერიერის სტილის switcher, real-time purchase configuration, build-stage tracking
- ფილტრები: სართული, ოთახები, ფართი, ბალკონი, ფასი/ქირა; გაყიდული ბინები ავტომატურად ქრება
- Favourites, compare, **Dynamic PDF** — პერსონალიზებული ბროშურა არჩეული ბინით
- **Back Panel CMS** + built-in CRM: funnel, lead scoring (hot/warm/cold ქცევიდან), campaign attribution; გარე: HubSpot, Odoo, Pipedrive, Microsoft 365
- Analytics: რამდენმა გახსნა ბინა, დრო, favourites, compare → demand ranking; Sale plan reports
- Embed, სრული საიტი, Mobile App, Kiosk App (offline touchscreen); CDN hosted ~2s load
- **ფასი:** tiers by size — Basic (≤6 units, 1 კვირა), Standard (≤250, 2 კვირა, + Kiosk), Extended (500+, 4 კვირა, + masterplan-to-unit zoom); "one-time build fee + per-unit fee + subscription", პირველი 6–12 თვე build-შია
- **კლიენტები:** Safa (KSA), Volkswagen Group, Colonia, Italicon; პროექტები პოლონეთში, შვეიცარიაში, ბულგარეთში, ხორვატიაში, ურუგვაიში, დომინიკანაში

---

## 5. 3D Twin (3D Estate Sp. z o.o.)

- **URL:** https://www.3dtwin.com/ · demo: https://demo.3destate.app/
- **ქვეყანა:** პოლონეთი (Mikołów/ვარშავა), ოფისები ლონდონი, მადრიდი; 400+ დეველოპერი, 2 000+ პროექტი, 500 000+ ბინის ტური

### Hero copy
"RESIDENTIAL EXPERIENCE ENGINE" — "Interactive 3D Property Tours & 3D Twins for Residential Real Estate Marketing"

### Sitemap
Home · Solutions `/digital-real-estate-marketing` → 3D Apartments `/property-virtual-tours`, 3D Twin CORE `/3d-real-estate`, COMFORT `/interactive-rendering`, ELITE `/renders-cgi`, + Free Presenter `/interactive-mockup` · Case Study `/real-estate-visualisation` · About `/about-us` · Blog · Contact · Demo

### Features (პაკეტებით)
- **3D Apartments:** Virtual Tour 3D, 3D Top Views, Axonometric Views, მბრუნავი 360° მოდელი, 2 დიზაინ-სტილი; embed საიტზე/პორტალებზე (Obido/OLX — 40 000 ტური)
- **CORE** ("Help buyers find exactly what they need"): მბრუნავი 3D მოდელი კომპლექსის → ბინის არჩევა; advanced search filters; favourites compare; direct inquiry collection; **two-way CRM integration** "with any system"
- **COMFORT:** ხედი ყველა ბინის ბალკონიდან 360°, ფოტორეალისტური გარემო მეზობელი შენობების სიმაღლეებით/მანძილებით, Project Location Module, დღე/ღამე, 4K გალერეა
- **ELITE:** კამერის თავისუფალი მოძრაობა, დღის დროის დინამიკა, ფეხით walkthrough, Project Panorama, 4K მულტიმედია
- **Free Presenter:** Unreal Engine touchscreen აპი გაყიდვების ოფისისთვის, წუთობრივი დღის დროის ცვლა
- Tech: Azure + Unreal Engine; 80%+ ტრაფიკი მობილურიდან
- **ფასი:** არ ქვეყნდება; tiered packages
- **კლიენტები:** Robyg, YIT, Atal, Cordia, Acciona, Eiffage, Greystar, Dekpol, BPI Real Estate

---

## 6. GRIDIX

- **URL:** https://gridix.live/ · app: https://app.gridix.live/
- **ქვეყანა:** რუსულენოვანი, საერთაშორისო პოზიციონირება (დუბაი, ბალი, **საქართველო**, ყაზახეთი, თურქეთი, პოლონეთი); USD ფასები

### Hero copy
«ЦИФРОВАЯ ЭКОСИСТЕМА ПРОДАЖ НЕДВИЖИМОСТИ ДЛЯ ЗАСТРОЙЩИКОВ ДЕВЕЛОПЕРОВ» — «До +40% к конверсии в заявку, до 3 раз быстрее путь к сделке и до -30% стоимость привлечения. Единая платформа для управления проектами, аналитикой и агентской сетью.»
(EN: "Digital real estate sales ecosystem for developers — up to +40% lead conversion, 3× faster path to deal, −30% acquisition cost. One platform for projects, analytics and agent network.") CTA: 14 დღე უფასოდ.

### Sitemap
Возможности `/#why` · Решения `/#solution` · Тарифы `/тарифы/` · Партнерам `/affiliate-program` · Блог `/blog/` · Войти `sso.gridix.live` · App `app.gridix.live`

### Features
- **Смарт-каталог:** ინტერაქტიული კატალოგი, demand analytics, White Label + custom domain, 99+ ენა, დინამიური ფასწარმოქმნა, აგენტების ქსელი/პარტნიორთა კაბინეტი
- **Шахматка:** ინტერაქტიული შახმატკა real-time ფასებით/სტატუსებით
- **Master plan+ (PRO):** გენგეგმა → unit selector
- **Интерактивный план этажа** + embeddable floor-plan ვიჯეტი
- ხედები 2D; 3D არ არის დეკლარირებული
- Booking / online reservation payment (coming soon), AI Подбор (AI ბინის შერჩევა), ipoteka/installment მართვა, PDF პრეზენტაციები, custom fields, ვალუტა/ენა, როლები, bulk changes
- CRM: built-in + amoCRM, Bitrix24 ორმხრივი სინქი; ციფრულიზაცია 3–5 დღეში
- **ფასი:** START $299/თვე/პროექტი; PRO $599; Enterprise $2 000-დან; წლიური −30%; 14-დღიანი trial; partner program 20–50%
- **კლიენტები:** სახელები არ ქვეყნდება

---

## 7. Flatter

- **URL:** https://www.flatter.hu/en · demo: https://www.demo.flatter.hu/en
- **ქვეყანა:** უნგრეთი (ბუდაპეშტი)

### Hero copy
"A smarter way to sell apartments" — "Interactive. Intuitive. Insightful." — "Upload a few renderings and apartment data — your interactive sales platform goes live in days."

### Sitemap
Features · Demo `demo.flatter.hu/en` · References · About Us · Contact · Privacy `/privacy` · Terms `/terms` · Demo app: Site plan, Flat selector, Flat list, Map, Contact

### Features
- Site plan (3D) → Building selector → ბინის ბარათები სართულების მიხედვით → Details; "from the overall layout down to individual apartments"
- კორპუსის ხედი: რენდერების კარუსელი (4 მხარე) კლიკაბელური ბინებით; Flat list; Map
- ბინის ბარათი: სტატუსი (available/booked), სართული, ID, მ², ოთახები, ფასი, ტეგები (Terrace, Garden, Balcony, Penthouse), "Get a quote"
- Compare, share, favourites; ფილტრები; ბრენდის ფერები
- Built-in analytics (visitor counts, per-apartment interest, conversion trends); email notifications ახალ inquiry-ზე
- 4 ენა, მობილური; არქიტექტორთა გუნდი აშენებს 3D მოდელს; live 2–3 დღეში
- hosted subdomain (არა embed); CRM ინტეგრაცია/API არ არის ნახსენები
- **ფასი:** quote
- **კლიენტები:** Callis Ingatlan, Telepes utca 24, Palota Liget, Riverport II

---

## 8. Realty.cat (ООО «ИТ ЛАБОРАТОРИЯ»)

- **URL:** https://realty.cat/ · demo ЖК: https://jk.realty.cat/masterplan · demo КП: https://kp.realty.cat/plats
- **ქვეყანა:** რუსეთი (ნოვოსიბირსკი)

### Hero copy
«Шахматка для застройщика от 17 500 ₽/мес» — «Каталог для жилых комплексов и коттеджных посёлков» — «Realty — интерактивный каталог, который встраивается в ваш сайт. Актуальные остатки и цены на сайте, удобный фильтр и возможность оставить заявку»
(EN: "Unit grid for developers from 17,500 RUB/mo — catalog for residential complexes and cottage villages — embeds into your site, live availability & prices, filter, lead form.")

### Sitemap
Главная `/` · Каталог на сайт `/catalog` · Каталог CRM `/crm` · Автоматизация `/automation` · Демо ЖК · Демо КП · Вход `login.realty.cat`

### Features
- Генплан (masterplan) → კორპუსი; Участки — კოტეჯების ნაკვეთები
- Шахматка (ყველა სართული სტატუსებით) · План этажа · Планировки (ფილტრი ტიპოლოგიით, ხელმისაწვდომობა სართულებად)
- Торговые предложения — რემონტის/ვარიანტების შეთავაზებები ბინაზე
- 2D only; embed საიტში ან subdomain
- Bitrix24-ში კატალოგი: მენეჯერის შახმატკა, იპოთეკის კალკულატორი, PDF პრეზენტაციების გენერაცია
- Акции მოდული, ფიდების ექსპორტი პორტალებზე, ონლაინ ანალიტიკა
- **ფასი:** 17 500 ₽/თვე-დან, მოდულური
- **კლიენტები:** МФК Freedom, ЖК Среда, КП Сердце Сибири, ЖК Смарт Парк, ЖК Биография და სხვ.

---

## Reference: შენ მიერ მითითებული ორი საიტი

### Profitbase — https://profitbase.ru/
- **Hero:** «Profitbase — цифровая экосистема для застройщика» — «Цифровой фундамент девелопера… объединяющая всех сотрудников и участников сделки в одном окне на единой платформе.» (600+ კლიენტი, 17 ქვეყანა, 10 წელი)
- **Sitemap:** Продукты и решения `/solutions` (Profitbase для CRM, Смарт-каталог `/smart-catalog`, Динамическое ценообразование, Онлайн-бронирование, Электронная сделка, Выдача ключей, Экспорт данных, Кабинет агента, Profitbase.BI) · Тарифы `/tariff` · Клиенты и кейсы · Партнёрство · Блог · Центр поддержки · О компании
- **Смарт-каталог features:** **8 ხედი** — Генплан, Интерактивный фасад, Список домов, Поэтажные планы, Планировки, Таблицы, Шахматка, Шахматка+; 3D ტურები Planoplan/Plankton-ით; გაფართოებული ბინის ბარათი (გალერეა, 3D ტური, custom fields, აქციები); 8 ტიპი უძრავი ქონება; favourites/compare; ონლაინ კომერციული შეთავაზება; online booking; CRM სინქი (amoCRM, Bitrix24, SberCRM, BPMSoft); widget code snippet-ით; Profitbase.BI
- **ფასი:** Смарт-каталог 20 700 ₽/თვე (393 600 ₽/წელი); CRM 4 004 ₽/თვე/user; bundles 295 600–711 000 ₽

### Flatris — https://flatris.com.ua/en/
- **Hero (RU):** «Продавайте квартиры Быстро. Дорого. Эффективно.» — «Flatris — система продвижения и продажи квартир для застройщика.»
- **Sitemap:** Products `/en/products/` (Interactive catalogue for website, Apartments grid for CRM, Placing on portals, Integration of agencies) · Tariffs `/en/plans` · For Partners `/en/affiliate-program` · Wiki `/en/wiki/` · Contacts · Login
- **Features:** 4 ტიპის არჩევა — crosstab, interactive catalogue, layouts, list with filters; ინტერაქტიული რუკები 2D სურათზე პოლიგონებით (ობიექტი → კორპუსი → სექცია → სართული; ადმინი თავად ხაზავს კონტურებს); 2D/3D სტატიკური გეგმები + PDF; Google Sheets როგორც inventory source; real-time სტატუსები; ფასდაკლებები ვადით, იპოთეკის ველები; CRM — Kommo/amoCRM, Pipedrive, Bitrix24, Uspacy; GA4; XML ფიდები (LUN, DOM.RIA…); აგენტების კაბინეტი; unlimited users
- **ფასი:** START 300 / STANDARD 1 500 / PRO 12 000 / ENTERPRISE 50 000 ბინა; 14-დღიანი trial

---

## დამატებით ნანახი (studio/agency მოდელი, არა SaaS)

- **VisEngine** — https://visengine.com/ (UK, დუბაი): "Architectural 3D Rendering Services Company"; Interactive Masterplan App `/interactive-masterplan-application/` — masterplan → phase → building → floor plan → unit, 360° ბრუნვა, დღე/ღამე, ფილტრი ბიუჯეტით/ფართით, AI assistant, 14+ CRM (Salesforce, HubSpot, Zoho, Bitrix24…), web/desktop/tablet/kiosk/Unreal streaming. კლიენტები: Emaar, Nakheel, Aldar, Sobha. Quote.
- **Redotree** — https://www.redotree.com/ (კრაკოვი): "Interactive Real Estate Visualization Platform"; Interactive Property Browser (development → building → floor → apartment), 3D floor plans, 360° ტურები, real-time availability, plugin installation; პაკეტები CORE/SHIFT/PRIME/ZEN (quote). CRM/analytics არ არის ნახსენები.
- **Virtuelle** — https://www.virtuelle.io/ (დუბაი/რიადი): bespoke Unreal/Unity გამოცდილებები (ROSHN, Arada, Ellington); unit selector/CRM არ არის აღწერილი — ზედმეტად custom.

---

## დასკვნები პროდუქტის დიზაინისთვის

1. **ბაზარი ორ ბანაკად იყოფა:** (a) 2D "შახმატკა"-ცენტრული SaaS (Profitbase, Flatris, Realty.cat, Gridix) — იაფი, სწრაფი onboarding, CRM-ზე ფოკუსი; (b) ნამდვილი 3D viewer-ები (3D Flat Finder, Your Next Home, Vinode, 3D Twin, Flat.show) — ძვირი production, მაგრამ ბევრად უკეთესი buyer experience. თავისუფალი ნიშა: **3D-ხარისხის flow self-serve SaaS ფასად**.
2. **საერთო core flow** ყველგან: გენგეგმა → კორპუსი (ფასადზე highlight) → სართული (გეგმა ან შახმატკა) → ბინის ბარათი (ფასი, სტატუსი, მ², ოთახები, გეგმა 2D/3D, ტური, PDF) → lead form. ეს minimum viable.
3. **დიფერენციატორები, რომელსაც ლიდერები ყიდიან:** ფასადზე hover-highlight (YNH), ბალკონის ხედი + მზის სიმულაცია (3DFF, 3D Twin), spatial filter 3D მოდელზე (3DFF), dynamic personalized PDF (Vinode), lead scoring ქცევიდან (Vinode, YNH), compare/favourites/share ყველგან.
4. **ინტეგრაციები** გადამწყვეტია: ორმხრივი CRM სინქი (Bitrix24/amoCRM პოსტ-საბჭოთა ბაზრისთვის; HubSpot/Salesforce დასავლეთისთვის), Google Sheets როგორც იაფი inventory source (Flatris), webhooks/API, XML ფიდები პორტალებზე.
5. **ფასების ბენჩმარკი:** $299–600/თვე/პროექტი (Gridix, YNH, 3DFF) ± setup €900; RU ბაზარი ~20 000 ₽/თვე. Free tier/sandbox (3DFF Creator Workspace) და 14-დღიანი trial სტანდარტია.
6. **Embed vs hosted:** უმეტესობა იძლევა iframe/snippet embed-ს + white-label subdomain-ს; kiosk/touchscreen რეჟიმი გაყიდვების ოფისისთვის ხშირი upsell-ია.

### წყაროები
https://www.flatshow.org/ · https://flat.show/landing/index.html · https://www.3dflatfinder.com/ · https://3dflatfinder.com/pricing.html · https://www.yournexthome.app/ · https://vinode.io/ · https://vinode.io/answers · https://www.3dtwin.com/ · https://3dtwin.com/3d-real-estate · https://gridix.live/ · https://gridix.live/тарифы/ · https://www.flatter.hu/en · https://www.demo.flatter.hu/en · https://realty.cat/ · https://realty.cat/catalog · https://profitbase.ru/smart-catalog · https://profitbase.ru/tariff · https://flatris.com.ua/en/products/interactive-chess-of-apartments-for-the-lcd-website · https://flatris.com.ua/en/plans · https://visengine.com/interactive-masterplan-application/ · https://www.redotree.com/ · https://www.virtuelle.io/
