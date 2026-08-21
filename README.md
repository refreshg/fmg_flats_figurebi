# ვერტიკალი — Odoo 19 მოდული

უძრავი ქონების დეველოპერისთვის: ბინების ინვენტარი Odoo-ს სტანდარტულ პროდუქტებად,
ვიზუალური ამომრჩევი (ფასადი → სართული → ბინა) და გაყიდვის ციკლი
opportunity-დან ჯავშნამდე.

**შიდა ინსტრუმენტია სეილს მენეჯერისთვის** — არა საჯარო ვიჯეტი.

## სტრუქტურა

| ფოლდერი | შიგთავსი |
|---|---|
| [`vertikali/`](vertikali/) | Odoo 19 მოდული |
| [`prototype/`](prototype/) | HTML პროტოტიპები (ფასადი, შახმატკა, სართული, ადმინის რედაქტორი) |
| [`research/`](research/) | კონკურენტების კვლევა, პატერნები, PRD, დიზაინი |
| [`CLAUDE.md`](CLAUDE.md) | **კონტექსტი, ტერმინოლოგია, გადაწყვეტილებები — წაიკითხე ჯერ** |

## ფუნქციონალი

**Estate** მენიუ:
- **Building Selector** — ვიზუალური ამომრჩევი: ფასადი / ზედხედი / შახმატკა.
  საფეხურები თითო პროექტზე ირთვება
- **Inventory → Units** — ბინები, ფილტრებით და ₾/მ²-ით
- **Configuration → Projects** — რომელი საფეხურები აქვს პროექტს
- **Configuration → Visual Views** — სურათები და ზონების რედაქტორი

## მოთხოვნები

- Odoo **19.0 Enterprise**
- დამოკიდებულებები: `product`, `sale_management`, `crm`, `sale_crm`, `stock`, `mail`

## ინსტალაცია

სერვერზე, git-იდან:

```bash
cd ~/vertikali-src && ./deploy.sh install   # პირველად
cd ~/vertikali-src && ./deploy.sh           # განახლება
```

`deploy.sh` ავტომატურად: pull → ვალიდაცია → addons-ში კოპირება →
`-i`/`-u` → სერვისის restart.

<details>
<summary>ხელით (deploy.sh-ის გარეშე)</summary>

```bash
sudo cp -r vertikali /opt/odoo/custom-addons/
sudo chown -R odoo:odoo /opt/odoo/custom-addons/vertikali
sudo systemctl stop odoo
sudo -u odoo /opt/odoo/odoo-19/venv/bin/python /opt/odoo/odoo-19/odoo-bin \
  -c /etc/odoo/odoo.conf -d odoo -i vertikali --stop-after-init --logfile=
sudo systemctl start odoo
```

`addons_path`-ში `/opt/odoo/custom-addons` უნდა იყოს ჩამატებული.
`--logfile=` აუცილებელია, თუ `odoo.conf`-ში `logfile` წერია — თორემ
შეცდომები ეკრანზე არ გამოჩნდება.
</details>

## არქიტექტურა — standard-first

მაქსიმალურად Odoo-ს სტანდარტული ფუნქციონალი; custom კოდი მხოლოდ იქ,
სადაც დადასტურდა რომ სტანდარტი ვერ ფარავს.

| საჭიროება | გადაწყვეტა |
|---|---|
| ბინა | `product.template` (`vk_is_unit` ჩამრთველით) |
| ბინის კოდი | `default_code` — `A-0504` |
| პროექტი → კორპუსი | `product.category.parent_id` (იერარქიული) |
| opportunity → შეთავაზებები | `crm.lead.order_ids` — სტანდარტული |
| ჯავშანი → გაყიდვა | `sale.order.state` |

**Custom:** ბინის ველები (`vk_*`), ₾/მ² (computed), პოლიგონები, შახმატკა.

### რატომ რეალური ველები და არა Properties

`product.template.product_properties` არსებობს, მაგრამ Properties-ზე computed ველი
არ დაიშვება და group-by/sort შეზღუდულია. ₾/მ² სორტირებადი უნდა იყოს — ამიტომ
კრიტიკული ველები რეალურია. მეორეხარისხოვანისთვის (ხედი, რემონტი) Properties რჩება.

## ვერსიონირება

`main` — სტაბილური. ცვლილება ჯერ git-ში, მერე სერვერზე.
