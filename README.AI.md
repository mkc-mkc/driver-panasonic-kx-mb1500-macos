# Panasonic KX-MB1500 series driver

Нативный CUPS-драйвер печати и установочные скрипты для Panasonic KX-MB1500 series на macOS.

## Текущий статус

- Скрипты поддерживают `KX-MB1500`, `KX-MB1500RU` и региональные варианты серии `KX-MB1500*`, включая суффиксы вроде `CX`, `HK`, `UC`.
- Серийные номера и локальные USB URI не хранятся в репозитории.
- Docker не используется во время печати или сканирования.
- Dockerfile оставлен только как build/research окружение.
- Нативный CUPS-фильтр `panasonic-kx-mb1500-gdi` реализован как universal Mach-O `arm64+x86_64`.
- Печать не требует Rosetta: системная очередь вызывает arm64 slice фильтра на Apple Silicon.
- Официальный macOS GDI-фильтр Panasonic непригоден для современных macOS ARM: он содержит только `i386/ppc`.
- Для «Захвата изображений» добавлен repair script: он чинит падение официального Panasonic ICA backend на новых macOS через локальный `CarbonShim.dylib`.

## Структура

- `printer/ppd/Panasonic_KX-MB1500-haikiri.ppd` - публичный PPD без локальных идентификаторов.
- `printer/filter/src/panasonic_kx_mb1500_gdi.c` - CUPS raster -> Panasonic GDI/JBIG фильтр.
- `scripts/build-filter.sh` - сборка universal фильтра `arm64+x86_64`.
- `scripts/install-driver.sh` - установка PPD, фильтра, создание CUPS-очереди и best-effort repair scanner backend.
- `scripts/verify-print.sh` - проверка очереди и отправка тестовой страницы в реальный USB-принтер.
- `scripts/repair-scanner-ica.sh` - ремонт установленного `Panasonic MFS Scanner.app` для Image Capture.
- `scripts/build-pkg.sh` - сборка `.pkg`, который ставит PPD, фильтр и helper-скрипты в систему.
- `printer/docker/Dockerfile` - build/research окружение, не runtime печати.
- `artifacts/` - локальные архивы/исходники Panasonic; содержимое не коммитится.

## Требования

- macOS с CUPS.
- Подключённый по USB Panasonic `KX-MB1500`, `KX-MB1500RU` или другой вариант серии `KX-MB1500*`.
- Command Line Tools (`clang`, `install_name_tool`) для сборки фильтра и ремонта старого Image Capture backend.
- Нативный фильтр устанавливается сюда:

```text
/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi
```

Фильтр принимает `application/vnd.cups-raster` и отдаёт Panasonic GDI/PJL поток.

## Сборка фильтра

```bash
./scripts/build-filter.sh
```

Результат:

```text
printer/filter/bin/panasonic-kx-mb1500-gdi
```

Проверка архитектур:

```bash
file printer/filter/bin/panasonic-kx-mb1500-gdi
```

Ожидаемо: `arm64` и `x86_64`.

## Установка из репозитория

```bash
./scripts/install-driver.sh
```

Команда установит PPD:

```text
/Library/Printers/PPDs/Contents/Resources/Panasonic_KX-MB1500-haikiri.ppd
```

Фильтр:

```text
/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi
```

И создаст CUPS-очередь по точному имени подключённой модели, например:

```text
Panasonic_KX_MB1500
Panasonic_KX_MB1500RU
Panasonic_KX_MB1500CX
```

Скрипт сам найдёт локальный USB URI через `lpinfo -v`; серийник не записывается в файлы проекта.

Дополнительно `install-driver.sh` теперь всегда пытается выполнить `repair-scanner-ica.sh` внутри основного install flow:

- если `Panasonic MFS Scanner.app` уже установлен, install flow попробует сразу починить ICA backend для `Image Capture`;
- если scanner app ещё не установлен, этот шаг будет просто пропущен;
- если repair scanner backend завершится ошибкой, установка печати всё равно не упадёт.

## Проверка печати после установки

После установки или переподключения USB-принтера стоит сразу прогнать отдельную проверку тракта печати:

```bash
./scripts/verify-print.sh
```

Скрипт делает только профильную проверку печати:

- убеждается, что очередь для реально подключённой модели серии `KX-MB1500*` существует;
- убеждается, что очередь привязана к точному локальному `usb://Panasonic/KX-MB1500...` URI;
- отправляет короткую тестовую страницу;
- ждёт, пока CUPS переведёт задание в `completed`;
- дополнительно сверяет успешное завершение по `error_log` CUPS.

Ожидаемый результат:

```text
Verified print path for Panasonic_KX_MB1500RU via job Panasonic_KX_MB1500RU-<id>
```

Для моделей без суффикса или с другим суффиксом имя очереди в выводе будет соответствовать точной модели, например `Panasonic_KX_MB1500` или `Panasonic_KX_MB1500CX`.

Это означает, что со стороны macOS/CUPS цепочка `text -> PDF -> CUPS raster -> panasonic-kx-mb1500-gdi -> usb backend` отработала без ошибки.

## Если очередь есть, но печать не идёт

Если в системном UI принтер виден, но задания зависают или появляется сообщение `Не удается отправить данные на принтер`, лучше не гадать, а пройти короткую проверку:

1. Убедиться, что очередь и USB URI живы:

```bash
lpstat -t
```

2. Включить подробный лог CUPS и повторить тест:

```bash
cupsctl --debug-logging
./scripts/verify-print.sh
```

3. Проверить, что в `error_log` для конкретного job есть нормальная последовательность:

```text
Started filter /Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi
Started backend /usr/libexec/cups/backend/usb
Job completed.
```

Если эта последовательность есть, то macOS успешно открыла USB-соединение, прогнала raster через наш нативный фильтр и отправила поток данных в принтер без backend-ошибки.

## Очистка старого Docker-runtime моста

Если ранее ставилась экспериментальная socket/Docker схема, её можно удалить:

```bash
./scripts/remove-legacy-runtime.sh
```

Этот скрипт удаляет старую очередь, LaunchAgent, старый `haikiri` log и системный фильтр `panasonic-mb1500-docker-filter`.

## Сборка pkg

```bash
./scripts/build-pkg.sh 0.1.0
```

Результат:

```text
dist/Panasonic-KX-MB1500-haikiri-0.1.0.pkg
```

Установка пакета:

```bash
sudo installer -pkg dist/Panasonic-KX-MB1500-haikiri-0.1.0.pkg -target /
```

Пакет ставит PPD, нативный фильтр и helper-скрипты. Если принтер подключён по USB во время установки, пакет также создаёт CUPS-очередь.

Scanner repair отдельно из `postinstall` больше не вызывается, потому что этот шаг уже встроен в основной `install-driver.sh` и всегда выполняется там в режиме best-effort.

## Архитектуры

Печатный runtime собирается как universal binary для `arm64` и `x86_64` (`amd64`).

Закрытый Linux-фильтр Panasonic можно использовать только как внешний build-time reference/oracle. Он не участвует в runtime, не ставится в систему и не вызывается CUPS.

## Сканер

### Что важно понимать заранее

Сканирование через стандартное приложение macOS `Image Capture` (`Захват изображений`) для `KX-MB1500` не работает “само по себе”.

Причина в том, что `Image Capture` является только системным UI и ожидает установленный ICA backend производителя. Для этой серии Panasonic таким backend является `Panasonic MFS Scanner.app`, который ставится из официального macOS-пакета `Multi-Function Station`.

Официальная страница Panasonic для Mac:

- [Panasonic Global: Mac driver page for KX-MB1500 series](https://docs.connect.panasonic.com/pcc/support/fax/common/table/macdriver.html)

Официальный прямой файл установщика, который сейчас доступен:

- [Mac_1.15.2.dmg](https://www.psn-web.net/cs/support/fax/common/file/Mac_Installer/Mac_1.15.2.dmg)

Panasonic на этой странице прямо указывает:

- `KX-MB1500 series` поддерживается этим `Mac_1.15.2.dmg`;
- официальная поддержка заявлена для `Mac OS X 10.5 - 10.11`;
- `macOS 10.15 or later is not supported`;
- на `10.12 - 10.14` часть функций может работать не полностью.

То есть на новых macOS это не “официально поддерживаемая” установка, а рабочий compatibility-path через старый Panasonic backend и наш repair-script.

### Полная настройка сканера с нуля

Ниже последовательность, которую можно выполнить с чистой системы, чтобы завести сканирование именно через `Image Capture`.

1. Подключить `Panasonic KX-MB1500*` по USB и включить устройство.

2. Если Mac на Apple Silicon, установить Rosetta, потому что официальный scanner backend Panasonic остаётся `x86_64`:

```bash
softwareupdate --install-rosetta --agree-to-license
```

3. Скачать официальный macOS-дистрибутив Panasonic:

- страница: [https://docs.connect.panasonic.com/pcc/support/fax/common/table/macdriver.html](https://docs.connect.panasonic.com/pcc/support/fax/common/table/macdriver.html)
- прямой файл: [https://www.psn-web.net/cs/support/fax/common/file/Mac_Installer/Mac_1.15.2.dmg](https://www.psn-web.net/cs/support/fax/common/file/Mac_Installer/Mac_1.15.2.dmg)

4. Открыть `Mac_1.15.2.dmg` и запустить `Install.pkg`.

5. Дождаться завершения установки Panasonic `Multi-Function Station`.

6. Проверить, что в системе действительно появился ICA backend Panasonic:

```bash
ls -la "/Library/Image Capture/Devices/Panasonic MFS Scanner.app"
```

Если этого `.app` нет, то дальше `Image Capture` не заработает, потому что системе не с чем разговаривать со сканером.

7. Перейти в корень этого репозитория и повторно запустить основной установщик:

```bash
./scripts/install-driver.sh
```

Этот запуск автоматически попытается выполнить repair scanner backend внутри себя.

8. Если нужен ручной повтор только scanner-ремонта, можно отдельно выполнить:

```bash
./scripts/repair-scanner-ica.sh
```

9. Открыть системное приложение `Image Capture`:

```bash
open -a "Image Capture"
```

10. В списке устройств выбрать `Panasonic KX-MB1500*`, задать папку назначения, формат и выполнить тестовый скан.

### Что делает repair-script

`Panasonic MFS Scanner.app` содержит matching для `04da:0f0b`, но на новых macOS падает при запуске из-за перенесённых ICA symbols:

```text
Symbol not found: _kICANotificationImageHeightKey
Expected in: /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon
```

`./scripts/repair-scanner-ica.sh` делает ровно следующее:

- собирает x86_64 `CarbonShim.dylib`;
- реэкспортирует через него системные `Carbon` и `ICADevices`;
- перепривязывает Panasonic binary с `Carbon.framework` на shim;
- переподписывает `.app` ad-hoc;
- перезапускает `icdd`, чтобы `Image Capture` увидел исправленный backend.

### Проверка результата

После установки Panasonic-пакета и прогона repair-script в системе должен существовать такой backend:

```bash
ls -la "/Library/Image Capture/Devices/Panasonic MFS Scanner.app"
```

А `Image Capture` должен показывать устройство без падения Panasonic backend при обращении к сканеру.

### Ограничения

- Без официального `Panasonic MFS Scanner.app` сканирование через `Image Capture` не заработает: одного принтера, PPD и CUPS-недостаточно.
- Официальный Panasonic macOS scanner backend остаётся `x86_64`, поэтому на Apple Silicon он зависит от Rosetta.
- Когда Apple окончательно уберёт Rosetta, для сканера понадобится либо нативный `arm64` backend, либо собственная реализация USB-протокола сканера без Panasonic software.
