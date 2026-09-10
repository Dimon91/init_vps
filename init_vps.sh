#!/usr/bin/env bash
#
# подготовка_vps.sh — подготовка VPS (Debian/Ubuntu) к работе
# по мотивам инструкции "Подготовка VPS.md"
#
# Что делает скрипт (запускается НА СЕРВЕРЕ от root):
#   1. apt update && apt full-upgrade
#   2. установка sudo (если отсутствует)
#   3. создание пользователя и добавление его в группу sudo
#   4. установка открытых SSH-ключей в ~user/.ssh/authorized_keys
#   5. настройка sshd (порт, запрет root, запрет паролей, AllowUsers)
#      через drop-in /etc/ssh/sshd_config.d/<file>.conf
#      (или правкой /etc/ssh/sshd_config, если каталога sshd_config.d нет)
#   6. проверка конфигурации (sshd -t) и перезапуск службы ssh
#
# Создание самой пары ключей (ssh-keygen) и ssh-copy-id выполняются НА КЛИЕНТЕ —
# в конце скрипт выведет готовые команды.
#
# Использование:
#   sudo bash подготовка_vps.sh              # полностью интерактивно
#   sudo bash подготовка_vps.sh --help       # список ключей
#
# ВАЖНО: не закрывайте текущий SSH-сеанс, пока не проверите вход
#        на новом порту в отдельном терминале!

set -Eeuo pipefail

# ------------------------------------------------------------------ пути ---
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"          # переопределяется для тестов
SSHD_CONFIG_D="${SSHD_CONFIG_D:-/etc/ssh/sshd_config.d}"
CONF_NAME="${CONF_NAME:-my_config.conf}"                    # имя drop-in файла

# ------------------------------------------------------------- настройки ---
DEFAULT_USER="user"
DEFAULT_PORT="10022"

USERNAME=""
SSH_PORT=""
KEY_COUNT=0
KEYS_INSTALLED=0
CURRENT_PORT=22            # порт sshd до изменения
USER_HOME=""
OPENSSH_VER=""
BACKUP_FILE=""
CONF_FILE=""
CONF_BACKUP=""
SSHD_BLOCK=()
PUBKEYS=()                # добавленные открытые ключи
ALLOW_USERS_EXTRA=""
DO_UPGRADE=1
DISABLE_PASSWORD_AUTH=1
DISABLE_ROOT_LOGIN=1
SET_PASSWORD=1            # 1 — adduser спросит пароль, 0 — создать без пароля
ASSUME_YES=0

# --------------------------------------------------------------- вывод -----
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

info()    { printf '%s==>%s %s\n'    "$C_BLU" "$C_RST" "$*"; }
success() { printf '%s[ok]%s %s\n'   "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s[!]%s %s\n'    "$C_YLW" "$C_RST" "$*" >&2; }
err()     { printf '%s[x]%s %s\n'    "$C_RED" "$C_RST" "$*" >&2; }
step()    { printf '\n%s────────────────────────────────────────%s\n' "$C_BLU" "$C_RST"; \
            printf '%s %s%s\n' "$C_BLU" "$*" "$C_RST"; \
            printf '%s────────────────────────────────────────%s\n' "$C_BLU" "$C_RST"; }

on_error() {
    err "Ошибка в строке $1 (код $2). Выполнение прервано."
    [[ -n "${BACKUP_FILE:-}" && -f "${BACKUP_FILE:-}" ]] && \
        warn "Резервная копия конфигурации sshd: $BACKUP_FILE"
}
trap 'on_error $LINENO $?' ERR

usage() {
    cat <<'USAGE'
Подготовка VPS к работе (запускать на сервере от root).

Ключи (если не указаны — будут запрошены интерактивно):
  -u, --user NAME          имя создаваемого пользователя
  -p, --port PORT          порт SSH-сервера
  -k, --key-file FILE      файл(ы) с открытым ключом (можно несколько раз)
      --allow-users LIST   список пользователей для AllowUsers (через пробел)
      --no-upgrade         пропустить apt full-upgrade
      --keep-password-auth не отключать вход по паролю
      --keep-root-login    не запрещать вход root
      --no-password        создать пользователя без пароля (только ключи)
  -y, --yes                не спрашивать подтверждений
  -h, --help               эта справка

Пример:
  sudo bash подготовка_vps.sh -u dimon -p 22222 -k /root/id_ed25519.pub
USAGE
}

# ------------------------------------------------------------ диалог -------
# read_prompt <переменная> <сообщение> [значение по умолчанию]
read_prompt() {
    local __var="$1" __msg="$2" __def="${3:-}" __val
    if [[ -n "$__def" ]]; then
        if ! read -r -p "$__msg [$__def]: " __val; then      # EOF: ввод недоступен
            warn "Ввод недоступен — беру значение по умолчанию: $__def"
            __val="$__def"
        fi
        printf -v "$__var" '%s' "${__val:-$__def}"
    else
        while :; do
            if ! read -r -p "$__msg: " __val; then           # EOF
                err "Ввод недоступен, а значение по умолчанию не задано."
                err "Передайте параметр командной строки (см. --help)."
                exit 1
            fi
            [[ -n "$__val" ]] && break
            err "Значение не может быть пустым."
        done
        printf -v "$__var" '%s' "$__val"
    fi
}

# confirm <сообщение> [default: y|n] -> код возврата 0 (да) / 1 (нет)
confirm() {
    local msg="$1" def="${2:-y}" ans hint
    if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
    if [[ "$def" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    while :; do
        ans=""
        if ! read -r -p "$msg [$hint]: " ans; then           # EOF
            warn "Ввод недоступен — беру ответ по умолчанию: $def"
            ans="$def"
        fi
        ans="${ans:-$def}"
        ans="${ans//[[:space:]]/}"          # убираем пробелы
        ans="${ans,,}"                      # в нижний регистр (в т.ч. кириллица)
        case "$ans" in
            y|yes|д|да|da)      return 0 ;;
            n|no|н|нет|net)     return 1 ;;
            *)                  err "Ответьте 'y' (да) или 'n' (нет)." ;;
        esac
    done
}

pause_for_check() {
    if [[ $ASSUME_YES -eq 1 || $TTY_IN -eq 0 ]]; then return 0; fi
    printf '\n%s' "$C_YLW"
    read -r -p ">>> Нажмите Enter, чтобы продолжить (Ctrl+C — прервать)... " _ || true
    printf '%s' "$C_RST"
}

valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# ---------------------------------------------------------------- аргументы -
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)              USERNAME="${2:?}"; shift 2 ;;
        -p|--port)              SSH_PORT="${2:?}"; shift 2 ;;
        -k|--key-file)          PUBKEYS+=("${2:?}"); shift 2 ;;
        --allow-users)          ALLOW_USERS_EXTRA="${2:?}"; shift 2 ;;
        --no-upgrade)           DO_UPGRADE=0; shift ;;
        --keep-password-auth)   DISABLE_PASSWORD_AUTH=0; shift ;;
        --keep-root-login)      DISABLE_ROOT_LOGIN=0; shift ;;
        --no-password)          SET_PASSWORD=0; shift ;;
        -y|--yes)               ASSUME_YES=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)                      err "Неизвестный параметр: $1"; usage; exit 1 ;;
    esac
done

# -------------------------------------------------------- предварительное ----
[[ $EUID -eq 0 ]] || { err "Скрипт нужно запускать от root (sudo bash $0)."; exit 1; }

# есть ли терминал для диалога
TTY_IN=0; [[ -t 0 ]] && TTY_IN=1
if [[ $TTY_IN -eq 0 ]]; then
    warn "Стандартный ввод не является терминалом: диалог невозможен,"
    warn "будут использованы значения по умолчанию и параметры командной строки."
    warn "Автоматический запуск: $0 -u ИМЯ -p ПОРТ [-k ФАЙЛ_КЛЮЧА] -y"
fi

if [[ ! -f "$SSHD_CONFIG" ]]; then
    info "openssh-server не установлен, устанавливаю..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y openssh-server
    success "openssh-server установлен."
fi

# бинарник sshd нужен для проверки конфигурации (sshd -t)
SSHD_BIN="${SSHD_BIN:-}"
if [[ -z "$SSHD_BIN" ]]; then
    SSHD_BIN="$(command -v sshd || true)"
    if [[ -z "$SSHD_BIN" ]]; then
        for c in /usr/sbin/sshd /sbin/sshd; do
            [[ -x "$c" ]] && SSHD_BIN="$c" && break
        done
    fi
fi
if [[ -z "$SSHD_BIN" || ! -x "$SSHD_BIN" ]]; then
    err "Не найден исполняемый файл sshd (нужен для проверки 'sshd -t')."
    err "Установите сервер: apt install openssh-server"
    exit 1
fi

banner() {
    cat <<BANNER

${C_BLU}==========================================================${C_RST}
${C_BLU}              ПОДГОТОВКА VPS-СЕРВЕРА К РАБОТЕ             ${C_RST}
${C_BLU}==========================================================${C_RST}
BANNER
}

collect_input() {
    # --- имя пользователя
    while [[ -z "$USERNAME" ]]; do
        read_prompt USERNAME "Имя создаваемого пользователя" "$DEFAULT_USER"
        if ! valid_username "$USERNAME"; then
            err "Некорректное имя пользователя (допустимы строчные латинские буквы, цифры, '_', '-')."
            USERNAME=""
        elif id -u "$USERNAME" >/dev/null 2>&1; then
            warn "Пользователь '$USERNAME' уже существует — он не будет создан заново."
            confirm "Использовать существующего пользователя '$USERNAME'?" y || USERNAME=""
        fi
    done

    # --- порт
    while [[ -z "$SSH_PORT" ]]; do
        read_prompt SSH_PORT "Порт SSH-сервера" "$DEFAULT_PORT"
        if ! valid_port "$SSH_PORT"; then
            err "Порт должен быть числом от 1 до 65535."
            SSH_PORT=""
        elif (( SSH_PORT < 1024 )); then
            warn "Порт $SSH_PORT — привилегированный (< 1024)."
            confirm "Оставить порт $SSH_PORT?" n || SSH_PORT=""
        elif [[ "$SSH_PORT" == "22" ]]; then
            warn "Порт 22 — стандартный, его постоянно сканируют боты."
            confirm "Оставить порт 22?" n || SSH_PORT=""
        fi
    done

    # --- пароль пользователя
    if [[ $TTY_IN -eq 0 ]]; then
        if [[ $SET_PASSWORD -eq 1 ]]; then
            warn "Нет терминала для ввода пароля — пользователь будет создан без пароля."
            SET_PASSWORD=0
        fi
    elif [[ $ASSUME_YES -eq 0 ]]; then
        info "По инструкции после создания пользователя нужно проверить вход по SSH"
        info "с паролем, и только затем отключать пароли. Хотите задать пароль?"
        if confirm "Задать пароль пользователю '$USERNAME' (adduser спросит его сам)?" y; then
            SET_PASSWORD=1
        else
            SET_PASSWORD=0
            warn "Пользователь будет создан без пароля — вход только по SSH-ключу."
        fi
    fi

    # --- дополнительные пользователи в AllowUsers
    if [[ -z "$ALLOW_USERS_EXTRA" ]]; then
        read -r -p "Дополнительные пользователи для AllowUsers (через пробел, пусто — только '$USERNAME'): " \
            ALLOW_USERS_EXTRA || ALLOW_USERS_EXTRA=""
    fi
    # проверка каждого имени, иначе опечатка может закрыть доступ нужному пользователю
    local ok="" u
    for u in $ALLOW_USERS_EXTRA; do
        if [[ "$u" == "$USERNAME" ]]; then
            continue
        elif valid_username "$u"; then
            ok+=" $u"
        else
            err "Имя '$u' не похоже на имя пользователя — оно НЕ будет добавлено в AllowUsers."
            confirm "Продолжить без '$u'?" y || exit 1
        fi
    done
    ALLOW_USERS_EXTRA="${ok# }"
}

show_plan() {
    local allow_list="$USERNAME ${ALLOW_USERS_EXTRA}"
    step "ПЛАН ДЕЙСТВИЙ"
    cat <<PLAN
  1. Обновление пакетов (apt update / full-upgrade) .......... $([[ $DO_UPGRADE -eq 1 ]] && echo "да" || echo "пропустить")
  2. Установка sudo (если не установлен) ..................... да
  3. Создание пользователя .................................. $USERNAME
     - группа sudo ........................................... да
     - пароль ................................................ $([[ $SET_PASSWORD -eq 1 ]] && echo "задать интерактивно" || echo "без пароля (только ключи)")
  4. Открытые SSH-ключи в ~$USERNAME/.ssh/authorized_keys .... $(( ${#PUBKEYS[@]} )) шт. (можно добавить ещё)
  5. Конфигурация sshd:
     - Port .................................................. $SSH_PORT
     - PermitRootLogin no .................................... $([[ $DISABLE_ROOT_LOGIN -eq 1 ]] && echo "да" || echo "нет")
     - PasswordAuthentication no ............................. $([[ $DISABLE_PASSWORD_AUTH -eq 1 ]] && echo "да" || echo "нет")
     - AuthenticationMethods publickey ....................... $([[ $DISABLE_PASSWORD_AUTH -eq 1 ]] && echo "да" || echo "нет")
     - X11Forwarding no ...................................... да
     - AllowUsers ............................................ $(echo $allow_list)
  6. sshd -t и перезапуск службы ssh .......................... да
PLAN
    echo
    confirm "Приступить к выполнению?" y || { info "Отменено пользователем."; exit 0; }
}

# ------------------------------------------------------------- шаги ---------

step_update_packages() {
    step "ШАГ 1. Обновление пакетов"
    export DEBIAN_FRONTEND=noninteractive
    info "apt update ..."
    apt-get update -y
    if [[ $DO_UPGRADE -eq 1 ]]; then
        info "apt full-upgrade (может занять несколько минут) ..."
        apt-get full-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
        success "Пакеты обновлены."
        if [[ -f /var/run/reboot-required ]]; then
            warn "Требуется перезагрузка сервера: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
        fi
    else
        info "Полное обновление пропущено (--no-upgrade)."
    fi
    return 0
}

step_install_sudo() {
    step "ШАГ 2. Установка sudo"
    if command -v sudo >/dev/null 2>&1; then
        success "sudo уже установлен: $(command -v sudo)"
    else
        info "Устанавливаю sudo ..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
        success "sudo установлен."
    fi
    return 0
}

step_create_user() {
    step "ШАГ 3. Создание пользователя '$USERNAME'"
    local home
    home="$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6)" || home=""

    if id -u "$USERNAME" >/dev/null 2>&1; then
        warn "Пользователь '$USERNAME' уже существует, пропускаю создание."
    else
        if [[ $SET_PASSWORD -eq 1 ]]; then
            info "Сейчас adduser попросит ввести пароль и данные пользователя."
            adduser --gecos "$USERNAME" "$USERNAME"
        else
            adduser --disabled-password --gecos "$USERNAME" "$USERNAME"
        fi
        success "Пользователь '$USERNAME' создан."
        home="$(getent passwd "$USERNAME" | cut -d: -f6)"
        if [[ -z "$home" ]]; then
            err "Не удалось определить домашний каталог пользователя '$USERNAME' после создания."
            exit 1
        fi
    fi

    # группа sudo (в Debian/Ubuntu) или wheel (в RHEL-подобных)
    local admin_group=""
    getent group sudo  >/dev/null 2>&1 && admin_group="sudo"
    [[ -z "$admin_group" ]] && getent group wheel >/dev/null 2>&1 && admin_group="wheel"
    if [[ -n "$admin_group" ]]; then
        usermod -aG "$admin_group" "$USERNAME"
        success "Пользователь добавлен в группу '$admin_group'."
    else
        warn "Группа sudo/wheel не найдена — права администратора нужно выдать вручную."
    fi

    if [[ -z "$home" || ! -d "$home" ]]; then
        err "Не удалось определить домашний каталог пользователя '$USERNAME' (получено: '${home:-пусто}')."
        exit 1
    fi
    USER_HOME="$home"

    # --- проверка входа (по инструкции: зайти под новым пользователем по ssh)
    info "Проверьте вход новым пользователем В ОТДЕЛЬНОМ ТЕРМИНАЛЕ:"
    echo "      ssh -p ${CURRENT_PORT:-22} ${USERNAME}@$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ $SET_PASSWORD -eq 1 ]]; then
        echo "      (вход по паролю; если успешно — завершите тот сеанс и вернитесь сюда)"
    else
        echo "      (пароль не задан — вход возможен только после добавления ключа)"
    fi
    pause_for_check
    return 0
}

# добавить один открытый ключ в authorized_keys пользователя
install_pubkey() {
    local key="$1" auth="$USER_HOME/.ssh/authorized_keys"

    # нормализация: убрать переводы строк и лишние пробелы
    key="$(printf '%s' "$key" | tr -d '\r' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')"

    if [[ ! "$key" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)(\ |$) ]]; then
        err "Это не похоже на открытый SSH-ключ: ${key:0:40}..."
        return 1
    fi
    if grep -qsxF "$key" "$auth"; then
        warn "Такой ключ уже есть в authorized_keys — пропускаю."
        return 0
    fi

    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.ssh"
    touch "$auth"
    chmod 600 "$auth"
    chown "$USERNAME:$USERNAME" "$auth"
    printf '%s\n' "$key" >> "$auth"
    success "Ключ добавлен: $(printf '%s' "$key" | awk '{print $1, $NF}')"
}

step_ssh_keys() {
    step "ШАГ 4. Настройка SSH-ключей"
    cat <<'TXT'
  Пару ключей создают НА КЛИЕНТЕ (вашем компьютере):
      cd ~/.ssh && ssh-keygen -t ed25519 -f my_vps_key
  а на сервер передают открытый ключ (my_vps_key.pub) — например командой
      ssh-copy-id -i ~/.ssh/my_vps_key.pub user@IP
  Здесь можно вставить содержимое открытого ключа или указать путь к файлу .pub,
  который уже загружен на сервер.
TXT
    echo

    # ключи, переданные через --key-file
    local f ans line
    for f in ${PUBKEYS[@]+"${PUBKEYS[@]}"}; do
        if [[ -f "$f" ]]; then
            install_pubkey "$(cat "$f")" || warn "Не удалось добавить ключ из $f"
        else
            err "Файл ключа не найден: $f"
        fi
    done

    # копирование ключа root (частый случай: зашли под root с ключом)
    if [[ -s /root/.ssh/authorized_keys ]] && [[ $ASSUME_YES -eq 0 ]]; then
        if confirm "Скопировать ключи root'а (/root/.ssh/authorized_keys) пользователю '$USERNAME'?" y; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && install_pubkey "$line" || true
            done < /root/.ssh/authorized_keys
        fi
    fi

    # интерактивное добавление
    while [[ $ASSUME_YES -eq 0 && $TTY_IN -eq 1 ]]; do
        echo
        read -r -p "Добавить открытый ключ? (вставьте ключ / путь к файлу .pub / 'н' — закончить): " ans || ans="н"
        [[ -z "$ans" ]] && continue
        case "${ans,,}" in
            n|no|н|нет|Н|НЕТ|Нет|net|q|quit|выход) break ;;
        esac

        if [[ -f "$ans" ]]; then
            info "Читаю ключ из файла: $ans"
            install_pubkey "$(cat "$ans")" || true
        else
            install_pubkey "$ans" || true
        fi
    done

    local auth="$USER_HOME/.ssh/authorized_keys"
    if [[ -s "$auth" ]]; then
        KEY_COUNT="$(wc -l < "$auth")"
        success "Ключей в $auth: $KEY_COUNT"
        KEYS_INSTALLED=1
    else
        KEY_COUNT=0
        KEYS_INSTALLED=0
        warn "Ни один ключ не добавлен!"
        warn "Добавьте ключ с клиента: ssh-copy-id -p ${CURRENT_PORT:-22} -i ~/.ssh/<ключ>.pub ${USERNAME}@<IP_сервера>"
        if [[ $DISABLE_PASSWORD_AUTH -eq 1 ]]; then
            err "Без ключа и с отключёнными паролями вы потеряете доступ к серверу."
            if [[ $ASSUME_YES -eq 0 ]]; then
                confirm "Отключить вход по паролю всё равно?" n || DISABLE_PASSWORD_AUTH=0
            else
                DISABLE_PASSWORD_AUTH=0
                warn "Вход по паролю НЕ отключается (нет ключей)."
            fi
        fi
    fi
    return 0
}

# формирование содержимого конфигурации sshd
build_sshd_block() {
    SSHD_BLOCK=()
    SSHD_BLOCK+=("# Создано скриптом подготовка_vps.sh $(date '+%Y-%m-%d %H:%M:%S')")
    SSHD_BLOCK+=("Port $SSH_PORT")
    [[ $DISABLE_ROOT_LOGIN -eq 1 ]] && SSHD_BLOCK+=("PermitRootLogin no")
    if [[ $DISABLE_PASSWORD_AUTH -eq 1 ]]; then
        SSHD_BLOCK+=("PasswordAuthentication no")
        # старое название опции (OpenSSH < 8.7)
        if [[ -n "${OPENSSH_VER:-}" ]] && [[ "$(printf '%s\n' "8.7" "$OPENSSH_VER" | sort -V | head -1)" == "8.7" ]]; then
            SSHD_BLOCK+=("KbdInteractiveAuthentication no")
        else
            SSHD_BLOCK+=("ChallengeResponseAuthentication no")
        fi
        SSHD_BLOCK+=("AuthenticationMethods publickey")
    fi
    SSHD_BLOCK+=("X11Forwarding no")
    SSHD_BLOCK+=("AllowUsers$(printf ' %s' $USERNAME $ALLOW_USERS_EXTRA)")
}

# определить порт, на котором sshd слушает сейчас (22, если явно не задан)
detect_current_port() {
    local f p
    for f in "$SSHD_CONFIG" ${SSHD_CONFIG_D:+"$SSHD_CONFIG_D"/*.conf}; do
        [[ -f "$f" ]] || continue
        p="$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' "$f" 2>/dev/null || true)"
        if [[ -n "$p" ]]; then printf '%s' "$p"; return 0; fi
    done
    printf '22'
}

# закомментировать все директивы из списка в файле (для режима без drop-in)
comment_directives() {
    local file="$1"
    sed -i -E \
        -e '/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|AuthenticationMethods|X11Forwarding|AllowUsers)([[:space:]]|$)/ s/^/# [vps-prepare] /' \
        "$file"
}

# откат конфигурации sshd к состоянию до запуска
rollback_config() {
    if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
        cp -a "$BACKUP_FILE" "$SSHD_CONFIG"
        warn "Восстановлен $SSHD_CONFIG из $BACKUP_FILE"
    fi
    if [[ -n "${CONF_BACKUP:-}" && -f "$CONF_BACKUP" ]]; then
        cp -a "$CONF_BACKUP" "$CONF_FILE"
        warn "Восстановлен $CONF_FILE из $CONF_BACKUP"
    elif [[ -n "${CONF_FILE:-}" && -f "$CONF_FILE" ]]; then
        rm -f "$CONF_FILE"
        warn "Удалён созданный этим запуском файл $CONF_FILE"
    fi
    return 0
}

step_sshd_config() {
    step "ШАГ 5. Настройка SSH-сервера"

    OPENSSH_VER="$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -1 | sed 's/OpenSSH_//' || true)"
    info "Версия OpenSSH: ${OPENSSH_VER:-не определена}"

    CURRENT_PORT="$(detect_current_port)"
    info "Текущий порт sshd: $CURRENT_PORT"

    # предупреждение о занятости порта другим процессом
    if command -v ss >/dev/null 2>&1; then
        local busy
        busy="$(ss -tlnp 2>/dev/null | awk -v p=":$SSH_PORT$" '$4 ~ p {print}' || true)"
        if [[ -n "$busy" && "$busy" != *"sshd"* ]]; then
            warn "Порт $SSH_PORT, похоже, уже занят другим процессом:"
            echo "$busy" >&2
            confirm "Всё равно использовать порт $SSH_PORT?" n || { err "Порт не изменён, выходим."; exit 1; }
        fi
    fi

    build_sshd_block
    info "Будет применена конфигурация:"
    printf '      %s\n' "${SSHD_BLOCK[@]}"

    TS="$(date +%Y%m%d-%H%M%S)"
    BACKUP_FILE="${SSHD_CONFIG}.bak.$TS"
    CONF_BACKUP=""
    cp -a "$SSHD_CONFIG" "$BACKUP_FILE"
    success "Резервная копия: $BACKUP_FILE"

    CONF_FILE="$SSHD_CONFIG_D/$CONF_NAME"

    if [[ -d "$SSHD_CONFIG_D" ]]; then
        # ---------- вариант 1: drop-in файл (как в инструкции) ----------
        if [[ -f "$CONF_FILE" ]]; then
            CONF_BACKUP="${CONF_FILE}.bak.$TS"
            cp -a "$CONF_FILE" "$CONF_BACKUP"
        fi
        info "Создаю файл конфигурации $CONF_FILE"
        printf '%s\n' "${SSHD_BLOCK[@]}" > "$CONF_FILE"
        chmod 644 "$CONF_FILE"

        # комментируем "Include /etc/ssh/sshd_config.d/*.conf" (по инструкции)
        sed -i -E '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf[[:space:]]*$/ s/^/#/' "$SSHD_CONFIG"

        # убираем старое упоминание нашего файла и добавляем Include В НАЧАЛО
        # (в sshd_config действует первое найденное значение, поэтому Include — сверху)
        sed -i -E "\@^[[:space:]]*#*[[:space:]]*Include[[:space:]]+$SSHD_CONFIG_D/$CONF_NAME[[:space:]]*\$@d" "$SSHD_CONFIG"
        { printf 'Include %s\n' "$CONF_FILE"; cat "$SSHD_CONFIG"; } > "${SSHD_CONFIG}.tmp"
        cat "${SSHD_CONFIG}.tmp" > "$SSHD_CONFIG"
        rm -f "${SSHD_CONFIG}.tmp"
        success "В $SSHD_CONFIG добавлено: Include $CONF_FILE"
    else
        # ---------- вариант 2: правим sshd_config напрямую ----------
        warn "Каталог $SSHD_CONFIG_D не существует — параметры прописываю прямо в $SSHD_CONFIG"
        comment_directives "$SSHD_CONFIG"
        { printf '%s\n' "${SSHD_BLOCK[@]}"; echo; cat "$SSHD_CONFIG"; } > "${SSHD_CONFIG}.tmp"
        cat "${SSHD_CONFIG}.tmp" > "$SSHD_CONFIG"
        rm -f "${SSHD_CONFIG}.tmp"
        success "Параметры добавлены в начало $SSHD_CONFIG."
    fi
    return 0
}

step_apply() {
    step "ШАГ 6. Проверка и применение конфигурации"

    info "Проверяю конфигурацию: $SSHD_BIN -t"
    if ! "$SSHD_BIN" -t; then
        err "Конфигурация некорректна! Служба НЕ перезапускается."
        rollback_config
        exit 1
    fi
    success "Конфигурация корректна."

    # определяем имя службы: в Debian/Ubuntu — ssh, в остальных — sshd
    local unit="ssh"
    if [[ ! -f /lib/systemd/system/ssh.service && ! -f /etc/systemd/system/ssh.service ]]; then
        unit="sshd"
    fi

    info "Перезапускаю службу: systemctl daemon-reload && systemctl restart $unit"
    systemctl daemon-reload
    systemctl restart "$unit"
    sleep 1
    if systemctl is-active --quiet "$unit"; then
        success "Служба $unit запущена."
    else
        err "Служба $unit не запустилась! Откатываю конфигурацию."
        rollback_config
        systemctl restart "$unit" || true
        err "Служба перезагружена со старой конфигурацией."
        exit 1
    fi

    # --- файрвол (в инструкции не описан, но без этого можно потерять доступ)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        warn "Обнаружен активный ufw. Если порт $SSH_PORT не разрешён — доступ пропадёт."
        if confirm "Разрешить в ufw порт $SSH_PORT/tcp?" y; then
            ufw allow "$SSH_PORT/tcp" comment 'SSH' || warn "Не удалось добавить правило ufw."
            success "Правило ufw добавлено: $SSH_PORT/tcp"
            if [[ "$CURRENT_PORT" != "$SSH_PORT" ]]; then
                info "Старое правило для порта $CURRENT_PORT можно удалить позже:"
                echo "      ufw delete allow $CURRENT_PORT/tcp"
            fi
        fi
    fi
    return 0
}

step_summary() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-<IP_адрес_сервера>}"

    cat <<SUMMARY

${C_GRN}==========================================================${C_RST}
${C_GRN}                ПОДГОТОВКА VPS ЗАВЕРШЕНА                  ${C_RST}
${C_GRN}==========================================================${C_RST}

  Пользователь ............. $USERNAME (группа sudo)
  Порт SSH ................. $SSH_PORT (был $CURRENT_PORT)
  Ключей в authorized_keys .. ${KEY_COUNT:-0}
  Вход root ................ $([[ $DISABLE_ROOT_LOGIN -eq 1 ]] && echo "запрещён" || echo "разрешён")
  Вход по паролю ........... $([[ $DISABLE_PASSWORD_AUTH -eq 1 ]] && echo "отключён, только ключи" || echo "разрешён")
  Разрешённые пользователи . $(echo $USERNAME $ALLOW_USERS_EXTRA)
  Конфиг ................... $([[ -f "$SSHD_CONFIG_D/$CONF_NAME" ]] && echo "$SSHD_CONFIG_D/$CONF_NAME" || echo "$SSHD_CONFIG")
  Резервная копия .......... ${BACKUP_FILE:-нет}

${C_YLW}  !! НЕ ЗАКРЫВАЙТЕ ТЕКУЩИЙ СЕАНС, пока не проверите вход !!${C_RST}
${C_YLW}  Если есть файрвол — разрешите порт $SSH_PORT/tcp${C_RST}

  Проверка в новом терминале:
      ssh -p $SSH_PORT $USERNAME@$ip

  Если ключ ещё не добавлен, с клиента:
      cd ~/.ssh
      ssh-keygen -t ed25519 -f my_vps_key
      ssh-copy-id -p $SSH_PORT -i ~/.ssh/my_vps_key.pub $USERNAME@$ip

  Откат конфигурации sshd:
      cp -a ${BACKUP_FILE:-$SSHD_CONFIG.bak} $SSHD_CONFIG && sshd -t && systemctl restart ssh

SUMMARY
}

# ---------------------------------------------------------------- запуск ----
main() {
    banner
    collect_input
    show_plan

    # порт, на котором sshd слушает сейчас — нужен в подсказках до смены порта
    CURRENT_PORT="$(detect_current_port)"

    step_update_packages
    step_install_sudo
    step_create_user
    step_ssh_keys
    step_sshd_config
    step_apply
    step_summary
}

main "$@"
