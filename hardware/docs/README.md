# Документы по железу

| Файл | Что |
|---|---|
| `hardware_log.md` | Журнал проектирования: вопросы, ответы, решения по шагам |
| `fabbit_bom.xlsx` | BOM материнки и мезонина, ножки ПЛИС и ESP, бюджет питания, решения, открытые вопросы |
| `bom/*.csv` | Выгрузка листов `fabbit_bom.xlsx` для диффов в git, руками не править |

Источник правды для BOM: `fabbit_bom.xlsx`. После правки xlsx перевыгрузи CSV:

```bash
python3 hardware/docs/xlsx2csv.py hardware/docs/fabbit_bom.xlsx hardware/docs/bom
```

Нужен `openpyxl`.
