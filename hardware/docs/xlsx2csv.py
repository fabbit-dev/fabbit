import openpyxl, csv, sys, re, pathlib
src, out = sys.argv[1], pathlib.Path(sys.argv[2])
names = {"BOM материнка":"mainboard","BOM мезонин":"mezzanine","Ножки ПЛИС":"fpga_pins","Ножки ESP32-S3":"esp_pins","Бюджет питания":"power_budget","Решения":"decisions","Открытые вопросы":"open_questions"}
wb = openpyxl.load_workbook(src, data_only=True)
for ws in wb:
    fn = out / (names.get(ws.title, re.sub(r'\W+','_',ws.title)) + ".csv")
    with open(fn, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        for r in ws.iter_rows(values_only=True):
            if any(c is not None for c in r):
                row = ["" if c is None else (round(c,3) if isinstance(c,float) else c) for c in r]
                while row and row[-1] == "": row.pop()
                w.writerow(row)
    print(fn)
