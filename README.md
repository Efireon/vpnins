# vpnins

Мой кривой скриптик, чтобы OpenConnect сам поднимался при наличии сети. `sudo ./ins-vpnctl.sh`, пара инпутов, и дальше оно само ставит systemd-юнит, обёртку, dispatcher для NetworkManager и polkit-правило. Работает на dnf, zypper, apt и pacman(но это не точно).

Дальше через `vpnctl`: enable, disable, start, stop, restart, status, auto, set-server, update. `disable` кладёт постоянный замок в `/var/lib/openconnect-auto/disabled` и выключает юнит, поэтому VPN не поднимается после перезагрузки и смены сети, пока не сделать `enable`. Логи смотреть в `journalctl -u openconnect-auto.service -f`.

Для обновления без потери настроек: `sudo vpnctl update` или `sudo ./ins-vpnctl.sh update`. Скрипт скачает свежую версию с GitHub, обновит себя и системные файлы (`vpnctl`, обёртку, юнит, dispatcher, polkit), а `/etc/openconnect/auto.env` и сертификаты не тронет.

**Steam Deck.** Скрипт сам снимает read-only ФС, фиксит кейринг и ставит openconnect. Запускать лучше файлом, а не через пайп - тогда вывод виден с самого начала:

```
wget -O /tmp/ins-vpnctl.sh https://raw.githubusercontent.com/Efireon/vpnins/refs/heads/main/ins-vpnctl.sh
sudo bash /tmp/ins-vpnctl.sh
```

Через `wget ... | sudo bash` тоже работает, но bash читает скрипт из пайпа целиком перед запуском, поэтому первые сообщения появятся с задержкой.
