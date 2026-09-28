# -*- coding: utf-8 -*-
"""The team's Excel matrix (saved as CSV) -> the price matrix in Odoo.

Reads the sheet exactly as Excel exports it: the first eleven columns are
the type rows (type, total, sold, remaining, current price, then three
stages of quantity + price). Empty rows and the totals row are skipped.
The sheet's side block (balcony %, parking, commercial) is ignored: the
matrix is about how the price per m² rises, not how a flat's price is
put together.

    python import_matrix.py "<sheet.csv>" --csv-out matrix_import.csv
        -> a clean CSV with Odoo field names, for ფასების მატრიცა >
           ტიპები და ფასები > Import (no code needed).

    python import_matrix.py "<sheet.csv>" --upload https://<host> --db <db> --key <password>
        [--name "ფიგურები 2026"] [--project "ფიგურები"]
        -> creates (or refreshes, by name) the matrix over XML-RPC with
           three stages. Re-running is safe: lines are matched by type code.
"""
import argparse, csv, io, sys, xmlrpc.client

# Georgian paths and labels in the console (Windows defaults to cp1252).
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

HEADERS = ['ტიპი', 'ჯამური რაოდენობა', 'გაყიდული/ფასით დაჯავშნილი რაოდენობა', 'დარჩენილი რაოდენობა',
           'მიმდინარე ფასები', 'საწყისი რაოდენობა', 'საწყისი ფასი', 'მეორე ეტაპის რაოდენობა',
           'მეორე ეტაპის ფასი', 'მესამე ეტაპის რაოდენობა', 'მესამე ეტაპის ფასი']
FIELDS = ['code', 'qty_total', 'qty_sold', None, None, 'qty_1', 'price_1', 'qty_2', 'price_2', 'qty_3', 'price_3']


def num(s, integer=False):
    s = (s or '').strip().replace(',', '').replace('%', '').replace(' ', '')
    if not s or s in ('-', '#REF!'):
        return 0
    v = float(s)
    return int(round(v)) if integer else v


def read_sheet(path):
    rows = list(csv.reader(io.open(path, encoding='utf-8-sig', newline='')))
    if [h.strip() for h in rows[0][:11]] != HEADERS:
        print('!! unexpected header row:', rows[0][:11]); sys.exit(1)
    lines = []
    for r in rows[1:]:
        r = r + [''] * (11 - len(r))
        code = r[0].strip()
        if not code:
            continue
        line = {'code': code}
        for i, f in enumerate(FIELDS):
            if f and f != 'code':
                line[f] = num(r[i], integer=f.startswith('qty'))
        line['sequence'] = 10 * len(lines) + 10
        lines.append(line)
    return lines


def write_csv(lines, out):
    cols = ['code', 'sequence', 'qty_total', 'qty_sold', 'qty_1', 'price_1', 'qty_2', 'price_2', 'qty_3', 'price_3']
    with io.open(out, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.writer(f)
        w.writerow(cols)
        for l in lines:
            w.writerow([l[c] for c in cols])
    print('written', len(lines), 'lines ->', out)


def upload(lines, url, db, key, name, project):
    common = xmlrpc.client.ServerProxy(url + '/xmlrpc/2/common')
    uid = common.authenticate(db, 'admin', key, {})
    if not uid:
        print('!! authentication failed'); sys.exit(1)
    rpc = xmlrpc.client.ServerProxy(url + '/xmlrpc/2/object')
    call = lambda model, meth, *a, **kw: rpc.execute_kw(db, uid, key, model, meth, list(a), kw)

    vals = {'name': name, 'stage_count': 3}
    if project:
        vals['project'] = project
    found = call('vertikali.price.matrix', 'search', [('name', '=', name)], limit=1)
    if found:
        mid = found[0]
        call('vertikali.price.matrix', 'write', [mid], vals)
        print('matrix', mid, 'updated')
    else:
        mid = call('vertikali.price.matrix', 'create', vals)
        print('matrix', mid, 'created')

    existing = {l['code']: l['id'] for l in call(
        'vertikali.price.matrix.line', 'search_read', [('matrix_id', '=', mid)], fields=['code'])}
    created = updated = 0
    for l in lines:
        if l['code'] in existing:
            call('vertikali.price.matrix.line', 'write', [existing[l['code']]], l); updated += 1
        else:
            call('vertikali.price.matrix.line', 'create', dict(l, matrix_id=mid)); created += 1
    print('lines: %d created, %d updated' % (created, updated))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sheet')
    ap.add_argument('--csv-out')
    ap.add_argument('--upload', metavar='URL')
    ap.add_argument('--db')
    ap.add_argument('--key')
    ap.add_argument('--name', default='ფასების მატრიცა')
    ap.add_argument('--project')
    a = ap.parse_args()
    lines = read_sheet(a.sheet)
    print('%d types, %d units' % (len(lines), sum(l['qty_total'] for l in lines)))
    if a.csv_out:
        write_csv(lines, a.csv_out)
    if a.upload:
        if not (a.db and a.key):
            print('!! --upload needs --db and --key'); sys.exit(1)
        upload(lines, a.upload, a.db, a.key, a.name, a.project)


if __name__ == '__main__':
    main()
