# Native filter target

Runtime не должен зависеть от Docker, Rosetta, Linux VM или пользовательского daemon.

Ожидаемый файл:

```text
/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi
```

CUPS вызывает фильтр так:

```text
panasonic-kx-mb1500-gdi job user title copies options [file]
```

Фильтр должен:

1. Читать CUPS raster из `file` или `stdin`.
2. Учитывать PPD options: `PageSize`, `Resolution`, `InputSlot`, `MediaType`, `TonerSave`, `Collate`.
3. Писать Panasonic KX-MB1500 GDI/PJL поток в `stdout`.
4. Работать нативно на `arm64` и `x86_64`.

PPD обязан указывать на системный Panasonic path:

```text
/Library/Printers/Panasonic/Filter/panasonic-kx-mb1500-gdi
```

Закрытый Panasonic Linux-фильтр можно использовать только как reference/build-time oracle, но не как runtime.
