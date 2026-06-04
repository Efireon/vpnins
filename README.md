# vpnins

Мой кривой скриптик, чтобы OpenConnect сам поднимался при наличии сети. `sudo ./ins-vpnctl.sh`, пара инпутов, и дальше оно само ставит systemd-юнит, обёртку, dispatcher для NetworkManager и polkit-правило. Работает на dnf, zypper, apt и pacman(но это не точно).

Дальше через `vpnctl`: enable, disable, start, stop, restart, status, auto. `disable` ставит замок, чтобы dispatcher не поднимал VPN сам, `enable` его снимает. Логи смотреть в `journalctl -u openconnect-auto.service -f`.
