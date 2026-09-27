# Работа с репозиторием

`main` защищён. Изменения попадают туда только через pull request.

## Цикл

```bash
git switch main && git pull
git switch -c feat/spi-receiver
# работа
git add -A
git commit -m "feat(gateware): приёмник SPI"
git push -u origin HEAD            # -u только в первый push
gh pr create --fill
gh pr merge --squash --delete-branch
git switch main && git pull
```

Следующий коммит в ту же ветку: `git add -A && git commit -m "..." && git push`.

## Ветки

| Префикс | Для чего | Пример |
|---|---|---|
| `feat/` | функция | `feat/jtag-loader` |
| `fix/` | исправление | `fix/spi-timeout` |
| `docs/` | документы | `docs/protocol-draft` |
| `hw/` | платы, корпус | `hw/mainboard-rev-a` |
| `journal/` | дневник | `journal/week-01` |

Ветка на одну задачу, один-два дня.

## Коммиты

`тип(область): что сделано`, по-русски. Область: верхний каталог.
Типы: `feat`, `fix`, `docs`, `hw`, `chore`, `refactor`, `test`.
Одно изменение, один коммит.

```
feat(gateware): генератор развёртки
fix(firmware): таймаут ожидания конфигурации
hw(mainboard): гнездо модуля ПЛИС
```

Версию хранит коммит. Не заводи `_v1`, `_new`, копии файлов.

## Журнал

```bash
cp journal/_template.md journal/$(date +%F).md
```

Фото: `journal/img/ГГГГ-ММ-ДД-описание.jpg`, до 2 МБ. Git LFS нет, фото
остаётся в истории навсегда.

```bash
ffmpeg -i снимок.jpg -vf scale=1600:-1 -q:v 3 journal/img/2026-09-25-плата.jpg
find journal/img -size +2M        # пусто = порядок
```

## Ревизии платы

Файлы ушли на завод, ставь тег:

```bash
git tag mainboard-rev-a && git push origin mainboard-rev-a
```

`git show mainboard-rev-a` покажет, что заказывали.

## Состояние

```bash
git status -sb
git diff            # не добавлено
git diff --staged   # добавлено, не закоммичено
git log --oneline -10
gh pr status
```

## Нельзя

* Push в `main` и `git push --force` в общие ветки.
* Коммитить `.bit`, `.bin`, герберы, `.stl`: они идут в GitHub Releases.
* Коммитить фото без сжатия.
* Держать ветку неделями.
* Удалять `.gitkeep`: git не хранит пустые каталоги.
