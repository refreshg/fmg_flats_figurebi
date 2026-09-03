# FIGUREBI გადახდის კალკულატორი — ინსტალაცია on-premise სერვერზე

**მოთხოვნა:** Odoo **19** (Community ან Enterprise). მოდული სხვა ვერსიებზე არ დადგება.

> ✅ **სტატუსი (2026-09-02):** მოდული (v19.0.2.1.0) წარმატებით დაინსტალირდა და გატესტილია
> რეალურ on-premise სერვერზე (46.233.53.183, Odoo 19 Enterprise) ამავე ინსტრუქციით.

⚠️ Apps → „Import Module" ღილაკით ეს მოდული **ვერ აიტვირთება** — ის Python-კოდიან
მოდულებს არ იღებს. ფოლდერი სერვერის დისკზე უნდა ჩაიდოს.

## Linux

```bash
# 1. აიტანეთ figurebi_installment.zip სერვერზე (scp/WinSCP) და გახსენით:
unzip figurebi_installment.zip -d /tmp/

# 2. ნახეთ custom addons გზა:
grep addons_path /etc/odoo/odoo.conf
# (ხშირად: /mnt/extra-addons ან /opt/odoo/custom-addons)

# 3. გადაიტანეთ და მიეცით უფლებები (გზა შეცვალეთ თქვენი addons_path-ით):
sudo mv /tmp/figurebi_installment /mnt/extra-addons/
sudo chown -R odoo:odoo /mnt/extra-addons/figurebi_installment

# 4. რესტარტი:
sudo systemctl restart odoo
```

## Windows Server

1. გახსენით zip და ფოლდერი `figurebi_installment` დააკოპირეთ Odoo-ს custom addons
   დირექტორიაში (გზა წერია `odoo.conf`-ის `addons_path` პარამეტრში)
2. Services → Odoo → **Restart**

## ბრაუზერიდან (ორივე შემთხვევაში)

1. შედით ადმინისტრატორით → Settings → ჩამოსქროლეთ ბოლომდე → **Activate the developer mode**
2. **Apps** → ზედა მენიუ **⋮ → Update Apps List** → Update
3. ძებნაში ჩაწერეთ `FIGUREBI` → **„FIGUREBI გადახდის კალკულატორი"** → **Activate**

## ინსტალაციის შემდეგ (კონფიგურაცია)

0. ⚠️ **აუცილებელი:** Settings → Sales → Pricing → ჩართეთ **Discounts**
   (`group_discount_per_so_line`) და Save. ამის გარეშე ფასდაკლება/ფასნამატი ხაზის
   Disc.%-მდე ვერ აღწევს და ჯამური ფასი არ იცვლება (გამოცდილი პრობლემაა).
0a. ⚠️ **აუცილებელი:** developer mode → Settings → Technical → **Decimal Accuracy** →
   „Discount" → digits = **6**. ამის გარეშე ფასდაკლების პროცენტი 2 ათწილადზე მრგვალდება
   და საბოლოო ფასი ზუსტად ვერ ჯდება (გამოცდილი პრობლემაა).
1. **Settings → CRM → FIGUREBI** — აირჩიეთ ინგლისურენოვანი და ქართულენოვანი ლიდების მენეჯერები
2. ბინის პროდუქტებზე შეავსეთ ველი **„ფართი (მ²)"** (ერთეულად დააყენეთ მ², ფასად — კვ.მ ფასი)
3. Settings → Companies — კომპანიის ლოგო/რეკვიზიტები (PDF-სა და იმეილში გამოჩნდება)
4. PDF-ბეჭდვას სჭირდება სერვერზე დაყენებული **wkhtmltopdf**

## თუ შეცდომა ამოვარდა

ინსტალაციისას გამოსული შეცდომის სრული ტექსტი (Traceback) გადაუგზავნეთ დეველოპერს —
გასწორებული ვერსია სწრაფად მომზადდება.
