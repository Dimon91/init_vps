# Обновление пакетов
```
apt update
apt full-upgrade
```
# Установка sudo (если нет)
`apt install sudo`
# Создание пользователя
```
adduser user
usermod -aG sudo user
```
После этого попробовать зайти под новым пользователем по ssh. Если успешно, завершаем сеанс и приступаем к добавлению ключей.
# Настройка ключей ssh
Можно не создавать новый ключ, а использовать существующий.
Создать можно так: на хосте

```
cd .ssh
ssh-keygen -t ed25519 -f <key_name>
```

Будут созданы закрытый ключ `key_name` (без расширения) и открытый `key_name.pub`. Открытый ключ нужно передать на сервер.

```
ssh-copy-id -i .ssh/key_name.pub user@<IP_адрес_сервера>
```

Команда добавит открытый ключ в конец файла `~/.ssh/authorized_keys`, где хранятся открытые ключи. Команда запросит пароль пользователя.
Если по какой-то причине эту команду использовать невозможно, можно вручную добавить открытый ключ в этот файл.

# Настройка ssh сервера
Создаем файл конфигурации `/etc/ssh/sshd_config.d/my_config.conf` со следующим содержимым:

```
Port 10022
PermitRootLogin no
PasswordAuthentication no
AuthenticationMethods publickey
X11Frowarding no
AllowUsers user
```

Прописываем этот файл в `/etc/ssh/sshd_config`: комментируем существующую настройку и добавляем путь к созданному файлу:

```
#Include /etc/ssh/sshd_config.d/*.conf
Include /etc/ssh/sshd_config.d/my_config.conf
```

Если каталога `/etc/ssh/sshd_config.d` не существует, то параметры прописываем непосредственно в файле `/etc/ssh/sshd_config`.

Проверка конфигурации `sshd -t`
Если проверка прошла, перезагружаем службу ssh `systemct restart ssh`

Для применения изменений

```
systemctl daemon-reload
systemctl restart ssh
```
