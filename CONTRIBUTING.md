# Как работать с репозиторием

`main` защищён. Прямой push отклоняется, изменения идут через pull request.

## Цикл работы

```bash
git switch main && git pull        # свежий main
git switch -c feat/spi-receiver   # ветка под задачу

# ... работа ...

git add -A
git commit -m "feat(gateware): приёмник SPI"
git push -u origin HEAD            # -u только в первый push ветки
gh pr create --fill
gh pr merge --squash --delete-branch
git switch main && git pull
```

Следующие коммиты в ту же ветку: `git add -A && git commit -m "..." && git push`.

## Имена ветвей

| Префикс | Для чего | Пример |
|---------|----------|--------|
| `feat/` | новая функция | `feat/jtag-loader` |
| `fix/` | исправление | `fix/spi-timeout` |
| `docs/` | документы | `docs/protocol-draft` |
| `hw/` | платы, корпус | `hw/mainboard-rev-a` |
| `journal/` | дневник | `journal/week-01` |

Одна ветка — одна задача, один-два дня.

## Коммиты

Формат `тип(область): что сделано`. Область — имя верхнего каталога.

```
feat(gateware): генератор развёртки
fix(firmware): таймаут ожидания конфигурации
docs(journal): запись за 25 сентября
hw(mainboard): гнездо модуля ПЛИС
chore(gitignore): маски файлов завода
```

Типы: `feat`, `fix`, `docs`, `hw`, `chore`, `refactor`, `test`.

Русский текст. Одно изменение — один коммит.

## Журнал

Новая запись:

```bash
cp journal/_template.md journal/$(date +%F).md
```

Фото в `journal/img/`, имя `ГГГГ-ММ-ДД-описание.jpg`. Сжать до 1–2 МБ: Git LFS
не подключён, файл остаётся в истории навсегда.

```bash
ffmpeg -i снимок.jpg -vf scale=1600:-1 -q:v 3 journal/img/2026-09-25-плата.jpg
```

Проверить перед коммитом. Пустой вывод — порядок.

```bash
find journal/img -size +2M
```

Ссылка в записи: `![Плата](img/2026-09-25-плата.jpg)`.

## Теги ревизий платы

Файлы ушли на завод — сразу тег:

```bash
git tag mainboard-rev-a
git push origin mainboard-rev-a
```

Плата придёт через два месяца, и `git show mainboard-rev-a` покажет, что
заказывали.

## Проверить состояние

```bash
git status -sb        # ветка и изменения
git diff             # изменено, не добавлено
git diff --staged    # добавлено, не закоммичено
git log --oneline -10
gh pr status
```

## Чего не делать

* Не пушить в `main` напрямую.
* Не делать `git push --force`.
* Не коммитить `.bit`, `.bin`, герберы, `.stl`. Они в `.gitignore` и идут в
  GitHub Releases.
* Не коммитить фото без сжатия.
* Не держать ветку неделями без слияния.
* Не удалять `.gitkeep` из пустого каталога: git не хранит пустые каталоги.
