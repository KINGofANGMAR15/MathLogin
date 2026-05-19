#!/bin/bash

# Script: parent-control-setup.sh
# Description: Установка системы родительского контроля

set -e

echo "=========================================="
echo "  Установка системы родительского контроля"
echo "=========================================="

# Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: Этот скрипт должен запускаться от имени root (sudo)"
    exit 1
fi

# Создание директорий
INSTALL_DIR="/opt/parent-control"
mkdir -p "$INSTALL_DIR"
mkdir -p /var/lib/parent-control

echo "[1/6] Создание основного скрипта..."

# Создание основного скрипта
cat > "$INSTALL_DIR/parent-control.sh" << 'MAINSCRIPT'
#!/bin/bash

# Script: parent-control.sh
# Description: Программа родительского контроля с проверкой арифметических примеров

DATA_DIR="/var/lib/parent-control"
LOCK_FILE="$DATA_DIR/locks.db"
USERS_FILE="$DATA_DIR/children.db"
LOG_FILE="$DATA_DIR/activity.log"
LOCK_DURATION=3600  # 1 час в секундах
MAX_ATTEMPTS=3

# Инициализация файлов
init_files() {
    mkdir -p "$DATA_DIR"
    touch "$LOCK_FILE" 2>/dev/null || true
    touch "$USERS_FILE" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

# Логирование
log_activity() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Генерация случайного примера
generate_problem() {
    local ops=('+' '-' '*')
    local op=${ops[$RANDOM % 3]}
    local num1=$((RANDOM % 20 + 1))
    local num2=$((RANDOM % 15 + 1))
    
    # Для деления确保 целочисленный результат
    if [[ $op == '*' ]]; then
        num1=$((RANDOM % 10 + 1))
        num2=$((RANDOM % 10 + 1))
    fi
    
    echo "$num1 $op $num2"
}

# Вычисление правильного ответа
calculate_answer() {
    local num1=$1
    local op=$2
    local num2=$3
    
    case $op in
        '+') echo $((num1 + num2)) ;;
        '-') echo $((num1 - num2)) ;;
        '*') echo $((num1 * num2)) ;;
    esac
}

# Проверка блокировки пользователя
is_locked() {
    local username="$1"
    local current_time=$(date +%s)
    
    if [[ -f "$LOCK_FILE" ]]; then
        while IFS=':' read -r user lock_time; do
            if [[ "$user" == "$username" ]]; then
                local elapsed=$((current_time - lock_time))
                if [[ $elapsed -lt $LOCK_DURATION ]]; then
                    local remaining=$((LOCK_DURATION - elapsed))
                    local hours=$((remaining / 3600))
                    local minutes=$(((remaining % 3600) / 60))
                    echo "$hours:$minutes"
                    return 0
                else
                    # Удаление истёкшей блокировки
                    grep -v "^$username:" "$LOCK_FILE" > "${LOCK_FILE}.tmp" 2>/dev/null || true
                    mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
                fi
            fi
        done < "$LOCK_FILE"
    fi
    return 1
}

# Блокировка пользователя
lock_user() {
    local username="$1"
    local current_time=$(date +%s)
    
    # Удаление старой блокировки если есть
    grep -v "^$username:" "$LOCK_FILE" > "${LOCK_FILE}.tmp" 2>/dev/null || true
    mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
    
    # Добавление новой блокировки
    echo "$username:$current_time" >> "$LOCK_FILE"
    log_activity "USER_LOCKED: $username заблокирован на $LOCK_DURATION секунд"
}

# Проверка существования детского аккаунта
is_child_user() {
    local username="$1"
    if [[ -f "$USERS_FILE" ]]; then
        grep -q "^$username$" "$USERS_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

# Добавление детского аккаунта
add_child_user() {
    local username="$1"
    if ! is_child_user "$username"; then
        echo "$username" >> "$USERS_FILE"
        log_activity "CHILD_USER_ADDED: $username"
        return 0
    fi
    return 1
}

# Список детских аккаунтов
list_child_users() {
    if [[ -f "$USERS_FILE" && -s "$USERS_FILE" ]]; then
        cat "$USERS_FILE"
    fi
}

# Вход с решением примера
child_login() {
    local username="$1"
    
    # Проверка блокировки
    local lock_remaining=$(is_locked "$username")
    if [[ $? -eq 0 ]]; then
        echo ""
        echo "❌ Аккаунт '$username' заблокирован!"
        echo "⏱️  Осталось времени блокировки: ${lock_remaining} (ч:м)"
        log_activity "LOGIN_BLOCKED: Попытка входа $username во время блокировки"
        return 1
    fi
    
    echo ""
    echo "📚 Пользователь: $username"
    echo "🧮 Решите пример для входа:"
    echo ""
    
    local attempts=0
    local success=false
    
    while [[ $attempts -lt $MAX_ATTEMPTS ]]; do
        local problem=$(generate_problem)
        read -r num1 op num2 <<< "$problem"
        local correct_answer=$(calculate_answer $num1 $op $num2)
        
        echo "Пример $((attempts + 1)): $num1 $op $num2 = ?"
        read -r user_answer
        
        # Проверка ответа
        if [[ "$user_answer" == "$correct_answer" ]]; then
            echo "✅ Правильно!"
            success=true
            log_activity "LOGIN_SUCCESS: $username успешно вошёл после $((attempts + 1)) попытки(ок)"
            break
        else
            echo "❌ Неправильно! Правильный ответ: $correct_answer"
            attempts=$((attempts + 1))
            log_activity "LOGIN_FAILED: $username неверный ответ (попытка $attempts из $MAX_ATTEMPTS)"
            
            if [[ $attempts -lt $MAX_ATTEMPTS ]]; then
                echo ""
            fi
        fi
    done
    
    if [[ "$success" == "false" ]]; then
        echo ""
        echo "⚠️  Превышено максимальное количество ошибок ($MAX_ATTEMPTS)!"
        echo "🔒 Аккаунт '$username' заблокирован на 1 час."
        lock_user "$username"
        return 1
    fi
    
    return 0
}

# Главное меню
show_menu() {
    echo ""
    echo "=========================================="
    echo "       СИСТЕМА РОДИТЕЛЬСКОГО КОНТРОЛЯ    "
    echo "=========================================="
    echo ""
    echo "Выберите вариант входа:"
    echo ""
    echo "  1) 🔐 Вход как администратор (root)"
    echo "  2) 👶 Вход как ребёнок"
    echo "  3) ⚙️  Управление детскими аккаунтами"
    echo "  4) 📊 Просмотр журнала активности"
    echo "  5) ❌ Выход"
    echo ""
    read -p "Ваш выбор [1-5]: " choice
    echo ""
    
    case $choice in
        1)
            echo "🔐 Вход с правами администратора"
            echo "-----------------------------------"
            echo "Введите пароль суперпользователя (root):"
            if sudo -v 2>/dev/null; then
                echo "✅ Аутентификация успешна!"
                log_activity "ADMIN_LOGIN: Успешный вход администратора"
                
                # Запуск оболочки от root
                echo "Запуск командной оболочки от имени root..."
                exec sudo -i
            else
                echo "❌ Неверный пароль или ошибка аутентификации"
                log_activity "ADMIN_LOGIN_FAILED: Неудачная попытка входа администратора"
            fi
            ;;
        2)
            echo "👶 Вход как ребёнок"
            echo "-----------------------------------"
            
            # Получение списка пользователей
            local users=$(list_child_users)
            
            if [[ -z "$users" ]]; then
                echo "⚠️  Нет зарегистрированных детских аккаунтов!"
                echo "Сначала создайте аккаунт через меню управления (пункт 3)"
                log_activity "NO_CHILD_USERS: Попытка входа при отсутствии аккаунтов"
            else
                echo "Доступные аккаунты:"
                echo "$users" | nl -w2 -s') '
                echo ""
                read -p "Введите имя пользователя или номер: " user_input
                
                local username=""
                if [[ "$user_input" =~ ^[0-9]+$ ]]; then
                    username=$(echo "$users" | sed -n "${user_input}p")
                else
                    username="$user_input"
                fi
                
                if [[ -n "$username" ]] && is_child_user "$username"; then
                    if child_login "$username"; then
                        echo ""
                        echo "🎉 Добро пожаловать, $username!"
                        log_activity "SESSION_STARTED: $username начал сессию"
                        
                        # Запуск ограниченной оболочки
                        echo "Запуск сеанса..."
                        exec sudo -u "$username" -i
                    fi
                else
                    echo "❌ Пользователь '$username' не найден!"
                    log_activity "INVALID_USER: Попытка входа под несуществующим пользователем $username"
                fi
            fi
            ;;
        3)
            manage_users
            ;;
        4)
            view_logs
            ;;
        5)
            echo "Выход из программы."
            exit 0
            ;;
        *)
            echo "❌ Неверный выбор. Попробуйте снова."
            ;;
    esac
}

# Управление пользовательскими аккаунтами
manage_users() {
    while true; do
        echo ""
        echo "⚙️  Управление детскими аккаунтами"
        echo "=========================================="
        echo ""
        echo "Текущие аккаунты:"
        local users=$(list_child_users)
        if [[ -z "$users" ]]; then
            echo "  (нет аккаунтов)"
        else
            echo "$users" | sed 's/^/  - /'
        fi
        echo ""
        echo "  1) ➕ Добавить аккаунт"
        echo "  2) ➖ Удалить аккаунт"
        echo "  3) 🔓 Снять блокировку"
        echo "  4) ↩️  Назад в главное меню"
        echo ""
        read -p "Ваш выбор [1-4]: " sub_choice
        echo ""
        
        case $sub_choice in
            1)
                read -p "Введите имя нового пользователя: " new_user
                if [[ -n "$new_user" ]]; then
                    # Проверка существования пользователя в системе
                    if id "$new_user" &>/dev/null; then
                        if add_child_user "$new_user"; then
                            echo "✅ Пользователь '$new_user' добавлен в систему родительского контроля"
                        else
                            echo "⚠️  Пользователь '$new_user' уже существует в списке"
                        fi
                    else
                        echo "❌ Системный пользователь '$new_user' не существует!"
                        echo "Сначала создайте пользователя командой: sudo useradd -m $new_user"
                    fi
                fi
                ;;
            2)
                read -p "Введите имя пользователя для удаления: " del_user
                if [[ -n "$del_user" ]]; then
                    if is_child_user "$del_user"; then
                        grep -v "^$del_user$" "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || true
                        mv "${USERS_FILE}.tmp" "$USERS_FILE"
                        echo "✅ Пользователь '$del_user' удалён"
                        log_activity "CHILD_USER_REMOVED: $del_user"
                    else
                        echo "❌ Пользователь '$del_user' не найден"
                    fi
                fi
                ;;
            3)
                read -p "Введите имя пользователя для разблокировки: " unlock_user
                if [[ -n "$unlock_user" ]]; then
                    if grep -q "^$unlock_user:" "$LOCK_FILE" 2>/dev/null; then
                        grep -v "^$unlock_user:" "$LOCK_FILE" > "${LOCK_FILE}.tmp" 2>/dev/null || true
                        mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
                        echo "✅ Блокировка с пользователя '$unlock_user' снята"
                        log_activity "USER_UNLOCKED: $unlock_user разблокирован администратором"
                    else
                        echo "ℹ️  Пользователь '$unlock_user' не заблокирован"
                    fi
                fi
                ;;
            4)
                break
                ;;
            *)
                echo "❌ Неверный выбор"
                ;;
        esac
    done
}

# Просмотр журнала
view_logs() {
    echo ""
    echo "📊 Журнал активности"
    echo "=========================================="
    echo ""
    
    if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
        echo "Последние 20 записей:"
        echo "-------------------"
        tail -20 "$LOG_FILE"
        echo ""
        read -p "Показать весь журнал? (y/n): " show_all
        if [[ "$show_all" == "y" || "$show_all" == "Y" ]]; then
            echo ""
            cat "$LOG_FILE"
        fi
    else
        echo "Журнал пуст"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Основная функция
main() {
    init_files
    log_activity "PROGRAM_STARTED: Запуск системы родительского контроля"
    
    # Приветственное сообщение
    echo ""
    echo "🛡️  Система родительского контроля запущена"
    echo "   Версия 1.0"
    
    # Основной цикл
    while true; do
        show_menu
    done
}

# Запуск программы
main "$@"
MAINSCRIPT

chmod +x "$INSTALL_DIR/parent-control.sh"

echo "[2/6] Создание скрипта автозапуска..."

# Создание systemd сервиса
cat > /etc/systemd/system/parent-control.service << 'SYSTEMDSERVICE'
[Unit]
Description=Parent Control System
After=getty.target
Before=login.service

[Service]
Type=idle
ExecStart=/opt/parent-control/parent-control.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
KillMode=mixed
Restart=no
User=root
Group=root

[Install]
WantedBy=multi-user.target
SYSTEMDSERVICE

echo "[3/6] Обновление конфигурации systemd..."

# Перезагрузка демонов systemd
systemctl daemon-reload

echo "[4/6] Создание тестового детского пользователя (опционально)..."

# Предложение создать тестового пользователя
read -p "Создать тестового детского пользователя 'child'? (y/n): " create_test
if [[ "$create_test" == "y" || "$create_test" == "Y" ]]; then
    if ! id "child" &>/dev/null; then
        useradd -m -s /bin/bash child
        echo "child:child123" | chpasswd
        echo "$INSTALL_DIR/parent-control.sh" >> /etc/rc.local 2>/dev/null || true
        echo "✅ Тестовый пользователь 'child' создан (пароль: child123)"
        echo "child" >> /var/lib/parent-control/children.db
    else
        echo "ℹ️  Пользователь 'child' уже существует"
    fi
fi

echo "[5/6] Настройка автозапуска..."

# Включение сервиса (но не запуск сразу, чтобы не мешать текущей сессии)
systemctl enable parent-control.service 2>/dev/null || true

echo "[6/6] Создание документации..."

# Создание README
cat > "$INSTALL_DIR/README.md" << 'README'
# Система родительского контроля

## Описание
Программа обеспечивает родительский контроль за входом в систему с следующими возможностями:

### Функции:
- **Вход администратора**: Требует пароль суперпользователя (root)
- **Детский вход**: Требует решение арифметического примера
- **Блокировка**: 3 неверных ответа блокируют аккаунт на 1 час
- **Управление аккаунтами**: Добавление/удаление детских учётных записей
- **Журналирование**: Логирование всех событий

## Расположение файлов
- Основной скрипт: `/opt/parent-control/parent-control.sh`
- База данных пользователей: `/var/lib/parent-control/children.db`
- Файл блокировок: `/var/lib/parent-control/locks.db`
- Журнал активности: `/var/lib/parent-control/activity.log`
- Systemd сервис: `/etc/systemd/system/parent-control.service`

## Использование

### Ручной запуск:
```bash
sudo /opt/parent-control/parent-control.sh
```

### Управление сервисом:
```bash
# Статус сервиса
systemctl status parent-control.service

# Остановить сервис
sudo systemctl stop parent-control.service

# Запустить сервис
sudo systemctl start parent-control.service

# Отключить автозапуск
sudo systemctl disable parent-control.service
```

### Добавление детского аккаунта:
1. Создайте системного пользователя: `sudo useradd -m username`
2. Запустите программу и выберите пункт 3 (Управление аккаунтами)
3. Добавьте пользователя в список контролируемых

## Как это работает

1. При загрузке ОС программа запускается автоматически на tty1
2. Пользователь выбирает тип входа:
   - **Администратор**: Ввод пароля root
   - **Ребёнок**: Решение арифметических примеров
3. При 3 неудачных попытках решения примера аккаунт блокируется на 1 час
4. Все действия логируются в файл журнала

## Требования
- Linux с systemd
- Права root для установки и запуска
- Bash 4.0+

## Безопасность
- Программа требует прав суперпользователя
- Пароли не хранятся в логах
- Блокировки сохраняются между перезагрузками
README

echo ""
echo "=========================================="
echo "  ✅ Установка завершена успешно!"
echo "=========================================="
echo ""
echo "📁 Файлы установлены в: $INSTALL_DIR"
echo "📝 Документация: $INSTALL_DIR/README.md"
echo ""
echo "🔄 Сервис настроен на автозапуск при загрузке ОС"
echo ""
echo "🚀 Для ручного тестирования запустите:"
echo "   sudo /opt/parent-control/parent-control.sh"
echo ""
echo "📋 Для управления сервисом используйте:"
echo "   systemctl status parent-control.service"
echo "   systemctl stop parent-control.service"
echo "   systemctl start parent-control.service"
echo ""
echo "⚠️  Примечание: Сервис настроен на запуск на tty1."
echo "   Для использования в графической среде может потребоваться"
echo "   дополнительная настройка."
echo ""
