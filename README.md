# VPSSetup

Интерактивная первичная настройка и защита VPS с Ubuntu Server 24.04:
обновления, пользователь с SSH-ключом, SSH-порт, UFW, Fail2ban и
автоматические security updates.

## Установка и запуск

Подключитесь к серверу и выполните:

```bash
wget -qO /tmp/vpssetup-install.sh https://raw.githubusercontent.com/goswoo/vpssetup/main/install.sh && sudo bash /tmp/vpssetup-install.sh
```

Установщик сразу запустит мастер. Укажите административного пользователя,
новый SSH-порт, пароль для `sudo` и публичный SSH-ключ.

Не закрывайте текущую SSH-сессию. После завершения мастера откройте вторую
сессию на выбранном порту:

```bash
ssh -p <PORT> <USER>@<SERVER>
sudo vpssetup ssh confirm
```

После подтверждения вход по старому порту и вход под `root` будут отключены.

## Управление

```bash
sudo vpssetup              # открыть меню
sudo vpssetup status       # показать состояние
sudo vpssetup health       # проверить конфигурацию
sudo vpssetup update       # обновить VPSSetup
sudo vpssetup rollback     # восстановить начальный snapshot
sudo vpssetup uninstall    # удалить менеджер
```
