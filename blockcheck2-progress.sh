#!/bin/bash

# Wrapper для blockcheck2.sh с прогресс-баром
# Использование: ./blockcheck2-progress.sh [параметры blockcheck2]

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR"; pwd)"
BLOCKCHECK2="$EXEDIR/blockcheck2.sh"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Символы прогресс-бара
PROGRESS_CHAR="█"
EMPTY_CHAR="░"

# Временные файлы
PROGRESS_FILE="/tmp/blockcheck2_progress_$$"
LOG_FILE="/tmp/blockcheck2_log_$$"
STAGE_FILE="/tmp/blockcheck2_stage_$$"

# Очистка при выходе
cleanup() {
    rm -f "$PROGRESS_FILE" "$LOG_FILE" "$STAGE_FILE"
    # Показать курсор
    tput cnorm 2>/dev/null
}
trap cleanup EXIT INT TERM

# Скрыть курсор
tput civis 2>/dev/null

# Функция отрисовки прогресс-бара
draw_progress() {
    local current=$1
    local total=$2
    local stage="$3"
    local width=50
    
    if [ $total -eq 0 ]; then
        return
    fi
    
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    # Очистить строку
    printf "\r\033[K"
    
    # Стадия
    printf "${CYAN}${BOLD}[%s]${NC} " "$stage"
    
    # Прогресс-бар
    printf "["
    printf "${GREEN}%${filled}s${NC}" | tr ' ' "$PROGRESS_CHAR"
    printf "%${empty}s" | tr ' ' "$EMPTY_CHAR"
    printf "]"
    
    # Процент и счетчик
    printf " ${BOLD}%3d%%${NC} ${CYAN}(%d/%d)${NC}" "$percent" "$current" "$total"
}

# Функция подсчета тестов
count_tests() {
    local test_type="$1"
    local test_dir="$EXEDIR/blockcheck2.d/$test_type"
    local count=0
    
    if [ -d "$test_dir" ]; then
        count=$(find "$test_dir" -name "*.sh" -type f | wc -l)
    fi
    
    echo $count
}

# Определение общего количества тестов
calculate_total_tests() {
    local test="${TEST:-standard}"
    local total=0
    
    # Базовые проверки (система, DNS, prerequisites)
    total=$((total + 3))
    
    # Подсчет тестовых скриптов
    local test_count=$(count_tests "$test")
    
    # Умножаем на количество доменов и IP версий
    local domains_count=$(echo "${DOMAINS:-rutracker.org}" | wc -w)
    local ipvs_count=$(echo "${IPVS:-4}" | wc -w)
    
    # Умножаем на включенные протоколы
    local protocols=0
    [ "${ENABLE_HTTP:-1}" = 1 ] && protocols=$((protocols + 1))
    [ "${ENABLE_HTTPS_TLS12:-1}" = 1 ] && protocols=$((protocols + 1))
    [ "${ENABLE_HTTPS_TLS13:-0}" = 1 ] && protocols=$((protocols + 1))
    [ "${ENABLE_HTTP3:-0}" = 1 ] && protocols=$((protocols + 1))
    
    # Общее количество тестов
    total=$((total + test_count * domains_count * ipvs_count * protocols))
    
    # Умножаем на количество повторов
    local repeats=${REPEATS:-1}
    total=$((total * repeats))
    
    echo $total
}

# Парсинг вывода blockcheck2
parse_output() {
    local line
    local current=0
    local total=$(calculate_total_tests)
    local stage="Инициализация"
    
    echo "0" > "$PROGRESS_FILE"
    echo "$stage" > "$STAGE_FILE"
    
    # Начальный прогресс-бар
    draw_progress 0 $total "$stage"
    
    while IFS= read -r line; do
        echo "$line" >> "$LOG_FILE"
        
        # Определение стадии
        if echo "$line" | grep -q "checking system"; then
            stage="Проверка системы"
            current=$((current + 1))
        elif echo "$line" | grep -q "checking DNS"; then
            stage="Проверка DNS"
            current=$((current + 1))
        elif echo "$line" | grep -q "checking prerequisites"; then
            stage="Проверка зависимостей"
            current=$((current + 1))
        elif echo "$line" | grep -q "curl_test_http "; then
            stage="Тест HTTP"
            current=$((current + 1))
        elif echo "$line" | grep -q "curl_test_https_tls12"; then
            stage="Тест HTTPS TLS 1.2"
            current=$((current + 1))
        elif echo "$line" | grep -q "curl_test_https_tls13"; then
            stage="Тест HTTPS TLS 1.3"
            current=$((current + 1))
        elif echo "$line" | grep -q "curl_test_http3"; then
            stage="Тест HTTP3 QUIC"
            current=$((current + 1))
        elif echo "$line" | grep -q "pktws_curl_test"; then
            current=$((current + 1))
        elif echo "$line" | grep -q "SUMMARY"; then
            stage="Формирование отчета"
        fi
        
        # Обновить прогресс
        echo "$current" > "$PROGRESS_FILE"
        echo "$stage" > "$STAGE_FILE"
        draw_progress $current $total "$stage"
        
        # Показать важные сообщения
        if echo "$line" | grep -qE "(AVAILABLE|working strategy|WARNING|ERROR)"; then
            printf "\n"
            if echo "$line" | grep -q "AVAILABLE"; then
                printf "${GREEN}✓${NC} %s\n" "$line"
            elif echo "$line" | grep -q "working strategy"; then
                printf "${GREEN}${BOLD}★${NC} %s\n" "$line"
            elif echo "$line" | grep -q "WARNING"; then
                printf "${YELLOW}⚠${NC} %s\n" "$line"
            elif echo "$line" | grep -q "ERROR"; then
                printf "${RED}✗${NC} %s\n" "$line"
            fi
            draw_progress $current $total "$stage"
        fi
    done
    
    # Финальный прогресс
    printf "\n\n"
}

# Главная функция
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         Zapret2 BlockCheck - Подбор стратегии DPI         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Проверка наличия blockcheck2.sh
    if [ ! -f "$BLOCKCHECK2" ]; then
        echo -e "${RED}Ошибка: blockcheck2.sh не найден в $EXEDIR${NC}"
        exit 1
    fi
    
    # Экспорт переменных окружения если они не установлены
    export TEST="${TEST:-standard}"
    export DOMAINS="${DOMAINS:-rutracker.org}"
    export IPVS="${IPVS:-4}"
    export ENABLE_HTTP="${ENABLE_HTTP:-1}"
    export ENABLE_HTTPS_TLS12="${ENABLE_HTTPS_TLS12:-1}"
    export ENABLE_HTTPS_TLS13="${ENABLE_HTTPS_TLS13:-0}"
    export ENABLE_HTTP3="${ENABLE_HTTP3:-0}"
    export REPEATS="${REPEATS:-1}"
    export SCANLEVEL="${SCANLEVEL:-standard}"
    export BATCH="${BATCH:-1}"
    
    echo -e "${CYAN}Параметры теста:${NC}"
    echo -e "  Домены: ${BOLD}$DOMAINS${NC}"
    echo -e "  IP версии: ${BOLD}$IPVS${NC}"
    echo -e "  Повторы: ${BOLD}$REPEATS${NC}"
    echo -e "  Уровень: ${BOLD}$SCANLEVEL${NC}"
    echo
    
    # Запуск blockcheck2 с парсингом вывода
    "$BLOCKCHECK2" "$@" 2>&1 | parse_output
    
    local exit_code=${PIPESTATUS[0]}
    
    # Показать полный лог если нужно
    if [ "$SHOW_FULL_LOG" = "1" ]; then
        echo
        echo -e "${CYAN}${BOLD}Полный лог:${NC}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
        cat "$LOG_FILE"
    fi
    
    # Итоговое сообщение
    echo
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ Тестирование завершено успешно!${NC}"
    else
        echo -e "${RED}${BOLD}✗ Тестирование завершено с ошибками (код: $exit_code)${NC}"
    fi
    
    echo
    echo -e "${CYAN}Для просмотра полного лога: ${BOLD}SHOW_FULL_LOG=1 $0${NC}"
    
    return $exit_code
}

# Запуск
main "$@"