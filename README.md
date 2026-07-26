# VPSSetup

`vpssetup` — интерактивный менеджер первичной настройки и hardening Ubuntu
Server 24.04. Он превращает чек-лист из `tasks/VPS setup.md` в повторяемую
процедуру с русским TUI, CLI, проверками, snapshots и безопасным двухфазным
переключением SSH.

## Что настраивается

- обновление пакетов, timezone `Europe/Moscow` и 24-часовой формат времени;
- административный пользователь с SSH-ключом и паролем только для `sudo`;
- SSH на настраиваемом порту (`60600` по умолчанию);
- UFW с сохранением текущего SSH-доступа и разрешённым `443/tcp`;
- Fail2ban и ежедневные unattended security upgrades без auto-reboot;
- опциональные swap, IPv6/Marzban, sudo timeout, Docker group и ICMP limiter.

## Локальная установка из checkout

```bash
sudo bash install.sh
```

Чтобы установить файлы без немедленного запуска мастера:

```bash
sudo bash install.sh --no-setup
sudo vpssetup
```

После публикации GitHub Release с файлами `vpssetup.tar.gz` и
`vpssetup.tar.gz.sha256` bootstrap можно запускать так:

```bash
export VPSSETUP_REPO="owner/repository"
curl -fsSL "https://raw.githubusercontent.com/${VPSSETUP_REPO}/main/install.sh" \
  -o /tmp/vpssetup-install.sh
sudo -E bash /tmp/vpssetup-install.sh
```

`owner/repository` намеренно не зашит: у текущего checkout пока нет Git remote.

## Безопасное переключение SSH

Мастер сначала включает старый и новый SSH-порты одновременно. Не закрывая
исходную сессию, откройте вторую:

```bash
ssh -p 60600 deploy@SERVER
sudo vpssetup ssh confirm
```

Только эта команда отключит root/password authentication и удалит созданное
`vpssetup` правило старого порта. Подтверждение отклоняется, если оно запущено
не пользователем `deploy` через `sudo` и не на новом порту. Для provider console
есть отдельный режим `--force-console` с вводом целевого порта.

## Основные команды

```text
sudo vpssetup
sudo vpssetup setup
sudo vpssetup status [--json]
sudo vpssetup health
sudo vpssetup ssh stage|confirm|status
sudo vpssetup module list|enable|disable NAME
sudo vpssetup backup create|list|restore
sudo vpssetup rollback
sudo vpssetup update
sudo vpssetup uninstall
```

Все системные изменения выполняются под lock. Перед опасными операциями
создаётся snapshot в `/var/lib/vpssetup/backups`. `uninstall` удаляет менеджер,
но не отменяет hardening; для явного восстановления предназначен `rollback`.
Пользователь и его ключи при rollback автоматически не удаляются.

## Проверки

```bash
find . -type f -name '*.sh' -exec bash -n {} \;
shellcheck vpssetup.sh install.sh lib/*.sh scripts/*.sh tests/*.sh
bash tests/run.sh
```

Sandbox-тесты проверяют state parser, модули, snapshots, SSH state machine и
JSON без изменения хоста. Финальную приёмку SSH/UFW/Fail2ban необходимо
выполнять на одноразовой Ubuntu 24.04 VM: контейнер или WSL не воспроизводят
полноценный сетевой и systemd-контур VPS.

## Ограничения

- поддерживается только Ubuntu 24.04;
- это single-server manager, а не fleet-management или remote SSH controller;
- reboot никогда не выполняется автоматически;
- ICMP limiter управляет только IPv4 echo-request и помечен experimental;
- `update` активируется после настройки GitHub Releases в
  `/etc/vpssetup/config.conf`.

