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

## მოთხოვნები

- Odoo **19.0 Enterprise**
- დამოკიდებულებები: `product`, `sale_management`, `crm`, `sale_crm`, `stock`, `mail`

## ინსტალაცია

```bash
# 1. მოდული addons path-ში
sudo cp -r vertikali /opt/odoo/custom-addons/
sudo chown -R odoo:odoo /opt/odoo/custom-addons/vertikali

# 2. ინსტალაცია
sudo systemctl stop odoo
sudo -u odoo /opt/odoo/odoo-19/venv/bin/python /opt/odoo/odoo-19/odoo-bin \
  -c /etc/odoo/odoo.conf -d odoo -i vertikali --stop-after-init
sudo systemctl start odoo
```

`addons_path`-ში `/opt/odoo/custom-addons` უნდა იყოს ჩამატებული.

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
