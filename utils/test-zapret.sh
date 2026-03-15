#!/bin/zsh

# Коды цветов
C_RESET="\033[0m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_CYAN="\033[36m"
C_GRAY="\033[90m"
C_DARKGRAY="\033[2;37m"
C_DARKCYAN="\033[36;2m"

# Глобальные переменные логирования
LOG_FILE=""
LOG_PATH=""

# --- Утилиты ---

colorize() {
  local text="$1" color="$2"
  echo "${color}${text}${C_RESET}"
}

write_log() {
  [[ -n "$LOG_FILE" ]] && echo "$1" >> "$LOG_FILE"
}

log_separator() {
  write_log "------------------------------------------------------------"
}

log_header() {
  local idx="$1" total="$2" config_name="$3"
  log_separator
  write_log "[$idx/$total] $config_name"
  log_separator
}

log_info() {
  echo "$(colorize "[INFO] $1" "$C_CYAN")"
  write_log "[INFO] $1"
}

log_warn() {
  echo "$(colorize "[WARN] $1" "$C_YELLOW")"
  write_log "[WARN] $1"
}

log_error() {
  echo "$(colorize "[ERROR] $1" "$C_RED")"
  write_log "[ERROR] $1"
}

log_ok() {
  echo "$(colorize "[OK] $1" "$C_GREEN")"
  write_log "[OK] $1"
}

init_log() {
  local log_dir="$1" test_type="$2"
  mkdir -p "$log_dir"

  local timestamp
  timestamp=$(date "+%Y-%m-%d-%H:%M:%S")
  local type_suffix
  [[ "$test_type" == "standard" ]] && type_suffix="standard" || type_suffix="dpi"
  LOG_PATH="$log_dir/test-zapret-${type_suffix}-${timestamp}.txt"
  LOG_FILE="$LOG_PATH"

  local header
  [[ "$test_type" == "standard" ]] && header="=== ZAPRET CONFIG STANDARD TEST LOG ===" || header="=== ZAPRET CONFIG DPI TEST LOG ==="
  echo "$header" > "$LOG_FILE"
  echo "Начало: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
  echo "=================================" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
}

close_log() {
  if [[ -n "$LOG_FILE" ]]; then
    echo "" >> "$LOG_FILE"
    echo "=================================" >> "$LOG_FILE"
    echo "Завершено: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    LOG_FILE=""
  fi
}

# --- Системные функции ---

detect_privilege_escalation() {
  command -v doas &>/dev/null && echo "doas" && return
  command -v sudo &>/dev/null && echo "sudo" && return
  echo ""
}

restart_zapret() {
  local elevate_cmd="$1"
  [[ -z "$elevate_cmd" ]] && return 1

  # macOS: launchctl
  if [[ "$(uname)" == "Darwin" ]]; then
    local plist="/Library/LaunchDaemons/zapret.plist"
    if [[ -f "$plist" ]]; then
      $elevate_cmd launchctl unload "$plist" 2>/dev/null
      $elevate_cmd launchctl load "$plist" 2>/dev/null
      if [[ $? -eq 0 ]]; then
        log_ok "Zapret перезапущен (launchctl)"
        return 0
      fi
    fi
  fi

  # systemd
  if command -v systemctl &>/dev/null; then
    if $elevate_cmd systemctl restart zapret 2>&1; then
      log_ok "Zapret перезапущен (systemd)"
      return 0
    fi
  fi

  # OpenRC
  if command -v rc-service &>/dev/null; then
    if $elevate_cmd rc-service zapret restart 2>&1; then
      log_ok "Zapret перезапущен (OpenRC)"
      return 0
    fi
  fi

  # runit
  if [[ -d /var/service/zapret ]] || [[ -d /etc/service/zapret ]]; then
    if $elevate_cmd sv restart zapret 2>&1; then
      log_ok "Zapret перезапущен (runit)"
      return 0
    fi
  fi

  # sysvinit
  if command -v service &>/dev/null; then
    if $elevate_cmd service zapret restart 2>&1; then
      log_ok "Zapret перезапущен (sysvinit)"
      return 0
    fi
  fi

  log_warn "Не удалось перезапустить zapret - система инициализации не обнаружена"
  return 1
}

# --- Функции анализа файлов ---

get_line_count() {
  [[ ! -f "$1" ]] && echo 0 && return
  wc -l < "$1" | tr -d ' '
}

file_contains_line() {
  local path="$1" line="$2"
  [[ ! -f "$path" ]] && return 1
  grep -qFx "$line" "$path"
}

get_ipset_status() {
  local ipset_file="$1"
  [[ ! -f "$ipset_file" ]] && echo "none" && return
  local line_count
  line_count=$(get_line_count "$ipset_file")
  [[ "$line_count" -eq 0 ]] && echo "any" && return
  file_contains_line "$ipset_file" "203.0.113.113/32" && echo "none" && return
  echo "loaded"
}

set_ipset_mode() {
  local mode="$1" ipset_file="$2" backup_file="$3"

  if [[ "$mode" == "any" ]]; then
    if [[ -f "$ipset_file" ]]; then
      cp "$ipset_file" "$backup_file"
      log_info "Backup ipset создан: $backup_file"
    else
      touch "$backup_file"
      log_info "Backup файл создан (исходный не существовал)"
    fi
    echo "" > "$ipset_file"
    log_info "IPSet очищен (режим 'any')"
  elif [[ "$mode" == "restore" ]]; then
    if [[ -f "$backup_file" ]]; then
      mv "$backup_file" "$ipset_file"
      log_info "IPSet восстановлен из backup"
    else
      log_warn "Backup файл не найден для восстановления"
    fi
  fi
}

# --- DPI ---

# Значения по умолчанию (переопределяются через MONITOR_* env vars)
DPI_TIMEOUT=${MONITOR_TIMEOUT:-5}
DPI_RANGE=${MONITOR_RANGE:-262144}
DPI_WARN_MIN_KB=${MONITOR_WARN_MINKB:-14}
DPI_WARN_MAX_KB=${MONITOR_WARN_MAXKB:-22}
DPI_MAX_PARALLEL=${MONITOR_MAX_PARALLEL:-8}
DPI_CUSTOM_URL="${MONITOR_URL:-}"

get_dpi_suite() {
  local url="https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.json"
  local output
  output=$(curl -s -m "$DPI_TIMEOUT" "$url" 2>/dev/null)
  [[ -z "$output" ]] && log_warn "Fetch dpi suite failed." && return

  # Парсим JSON — извлекаем id, provider, url, times
  # Используем python3 если доступен, иначе грубый парсинг
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for entry in data:
    print(entry.get('id','') + '|' + entry.get('provider','') + '|' + entry.get('url','') + '|' + str(entry.get('times',1)))
" <<< "$output"
  else
    # Грубый парсинг через grep/sed
    echo "$output" | grep -oE '"id":"[^"]+"' | sed 's/"id":"//;s/"//' | while read -r id; do
      echo "${id}|unknown|unknown|1"
    done
  fi
}

build_dpi_targets() {
  local custom_url="$1"

  if [[ -n "$custom_url" ]]; then
    echo "CUSTOM|Custom|$custom_url|1"
    return
  fi

  get_dpi_suite | while IFS='|' read -r id provider url times; do
    times=${times:-1}
    if [[ "$times" -le 1 ]]; then
      echo "${id}|${provider}|${url}"
    else
      for (( i=0; i<times; i++ )); do
        echo "${id}@${i}|${provider}|${url}"
      done
    fi
  done
}

# --- Функции тестирования ---

test_url() {
  local url="$1" timeout="$2" test_label="$3"
  local args=""

  case "$test_label" in
    HTTP)   args="--http1.1" ;;
    TLS1.2) args="--tlsv1.2 --tls-max 1.2" ;;
    TLS1.3) args="--tlsv1.3 --tls-max 1.3" ;;
  esac

  local output
  output=$(curl -I -s -m "$timeout" -o /dev/null -w '%{http_code} %{size_download}' --show-error $args "$url" 2>&1)
  local code=$?

  # Проверка на SSL ошибки
  if echo "$output" | grep -qiE 'Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate'; then
    echo "SSL 0"
    return
  fi

  local http_code size
  http_code=$(echo "$output" | grep -oE '^[0-9]+' | head -1)
  size=$(echo "$output" | grep -oE '[0-9]+$' | tail -1)

  if [[ -z "$http_code" ]]; then
    if echo "$output" | grep -qiE 'not supported|does not support|unsupported' || [[ "$code" -eq 35 ]]; then
      echo "UNSUP 0"
    else
      echo "ERR 0"
    fi
    return
  fi

  if [[ "$code" -eq 0 ]]; then
    echo "OK ${size:-0}"
  else
    echo "ERR 0"
  fi
}

test_ping() {
  local host="$1" count="$2"
  local output
  output=$(ping -c "$count" -W 2 "$host" 2>&1 | grep 'min/avg/max')

  if [[ -z "$output" ]]; then
    echo "Timeout"
    return
  fi

  local avg
  avg=$(echo "$output" | sed -E 's|.*/([0-9.]+)/.*|\1|')
  if [[ -n "$avg" ]]; then
    printf "%.0f ms" "$avg"
  else
    echo "Timeout"
  fi
}

load_targets() {
  local targets_file="$1"
  while IFS= read -r line; do
    # Пропускаем комментарии и пустые строки
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ ! "$line" =~ = ]] && continue

    local name value
    name=$(echo "$line" | sed -E 's/^[[:space:]]*([[:alnum:]_]+)[[:space:]]*=.*/\1/')
    value=$(echo "$line" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

    [[ -n "$name" && -n "$value" ]] && echo "${name}|${value}"
  done < "$targets_file"
}

run_standard_tests() {
  local config_name="$1" targets_file="$2" timeout="$3"
  echo "$(colorize "  > Запуск тестов..." "$C_DARKGRAY")"
  write_log "> Запуск тестов..."

  load_targets "$targets_file" | while IFS='|' read -r name value; do
    printf "  %-30s " "$name"

    if [[ "$value" == PING:* ]]; then
      local host="${value#PING:}"
      local result
      result=$(test_ping "$host" 3)
      echo "$(colorize "Пинг: $result" "$C_CYAN")"
      write_log "$(printf '%-30s Пинг: %s' "$name" "$result")"
    else
      local results_line="" log_line=""
      for test_label in HTTP TLS1.2 TLS1.3; do
        local output
        output=$(test_url "$value" "$timeout" "$test_label")
        local status="${output%% *}"

        local color="$C_GREEN"
        case "$status" in
          SSL|ERR) color="$C_RED" ;;
          UNSUP)   color="$C_YELLOW" ;;
        esac

        results_line+="$(colorize "${test_label}:${status}" "$color") "
        log_line+="${test_label}:${status} "
      done

      echo "$results_line"
      write_log "$(printf '%-30s %s' "$name" "$log_line")"
    fi
  done
}

run_dpi_tests() {
  local timeout="$1" range_bytes="$2" warn_min_kb="$3" warn_max_kb="$4"

  log_info "Целей: загрузка... Диапазон: 0-$((range_bytes - 1)) байт; Таймаут: ${timeout} с; Окно предупреждения: ${warn_min_kb}-${warn_max_kb} КБ"
  log_info "Запуск проверок DPI TCP 16-20..."

  local warn_detected=false

  build_dpi_targets "$DPI_CUSTOM_URL" | while IFS='|' read -r id provider url; do
    echo ""
    local header="=== $id [$provider] ==="
    echo "$(colorize "$header" "$C_DARKCYAN")"
    write_log "$header"

    local target_warned=false

    for test_label in HTTP TLS1.2 TLS1.3; do
      local output
      output=$(test_url "$url" "$timeout" "$test_label")
      local status="${output%% *}"
      local size="${output##* }"
      local size_kb=$(( size / 1024 ))
      local color="$C_GREEN"
      local msg_status="OK"

      case "$status" in
        SSL)  color="$C_RED";    msg_status="SSL_ERROR" ;;
        UNSUP) color="$C_YELLOW"; msg_status="НЕ_ПОДДЕРЖИВАЕТСЯ" ;;
        ERR)  color="$C_RED";    msg_status="ОШИБКА" ;;
      esac

      if [[ "$size_kb" -ge "$warn_min_kb" && "$size_kb" -le "$warn_max_kb" && "$status" == "ERR" ]]; then
        msg_status="ВЕРОЯТНО_ЗАБЛОКИРОВАНО"
        color="$C_YELLOW"
        target_warned=true
      fi

      local msg="  [$id][$test_label] code=$status size=$size bytes (~${size_kb} KB) status=$msg_status"
      echo "$(colorize "$msg" "$color")"
      write_log "$msg"
    done

    if [[ "$target_warned" == false ]]; then
      local msg="  Паттерн замораживания 16-20КБ не обнаружен для этой цели."
      echo "$(colorize "$msg" "$C_GREEN")"
      write_log "$msg"
    else
      local msg="  Паттерн совпадает с замораживанием 16-20КБ; цензор вероятно блокирует эту стратегию."
      echo "$(colorize "$msg" "$C_YELLOW")"
      write_log "$msg"
      warn_detected=true
    fi
  done

  echo ""
  if [[ "$warn_detected" == true ]]; then
    log_error "Обнаружена возможная блокировка DPI TCP 16-20 на одной или нескольких целях. Рассмотрите изменение стратегии/SNI/IP."
  else
    log_ok "Паттерн замораживания 16-20КБ не обнаружен на всех целях."
  fi
}

# --- Выбор конфигов ---

read_mode_selection() {
  while true; do
    echo ""
    echo "$(colorize "Выберите режим тестирования:" "$C_CYAN")"
    echo "  [1] Все конфиги"
    echo "  [2] Выбранные конфиги"
    printf "Введите 1 или 2: "
    read -r choice

    case "$choice" in
      1) echo "all"; return ;;
      2) echo "select"; return ;;
      *) echo "$(colorize "Неверный ввод. Попробуйте снова." "$C_YELLOW")" ;;
    esac
  done
}

select_configs() {
  local -a all_configs=("$@")

  while true; do
    echo ""
    echo "$(colorize "Доступные конфиги:" "$C_CYAN")"
    for (( i=1; i<=${#all_configs[@]}; i++ )); do
      printf "  [%2d] %s\n" "$i" "${all_configs[$i]}"
    done

    echo ""
    echo "Введите номера конфигов для тестирования (через запятую, например 1,3,5):"
    printf "> "
    read -r input

    local -a selected=()
    for num_str in ${(s:,:)input}; do
      local num="${num_str//[^0-9]/}"
      if [[ -n "$num" && "$num" -ge 1 && "$num" -le "${#all_configs[@]}" ]]; then
        selected+=("${all_configs[$num]}")
      fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
      echo "$(colorize "[WARN] Некорректный ввод. Попробуйте снова." "$C_YELLOW")"
    else
      echo "$(colorize "[OK] Выбрано конфигов: ${#selected[@]}" "$C_GREEN")"
      echo "${(j:\n:)selected}"
      return
    fi
  done
}

# --- Основной скрипт ---

main() {
  # Определяем директорию utils, где лежит сам скрипт
  local utils_dir="${0:a:h}"
  local root_dir="${utils_dir:h}"

  local configs_dir="$root_dir/configs"
  local targets_file="$utils_dir/targets.txt"
  local log_dir="$utils_dir/log"
  local zapret_config="/opt/zapret/config"
  local zapret_config_backup="/opt/zapret/config.back"

  # Проверка доступности curl
  if ! command -v curl &>/dev/null; then
    echo "$(colorize "[ERROR] curl не найден. Пожалуйста, установите curl." "$C_RED")"
    exit 1
  fi

  # Определение повышения привилегий
  local elevate_cmd
  elevate_cmd=$(detect_privilege_escalation)
  if [[ -z "$elevate_cmd" ]]; then
    echo "$(colorize "[ERROR] sudo или doas не найдены" "$C_RED")"
    exit 1
  fi
  echo "$(colorize "[OK] Повышение привилегий: $elevate_cmd" "$C_GREEN")"

  # Поиск всех файлов конфигов
  local -a configs=()
  for f in "$configs_dir"/*; do
    [[ ! -f "$f" ]] && continue
    local name="${f:t}"
    [[ "$name" == .* ]] && continue
    [[ "$name" == old* ]] && continue
    configs+=("$name")
  done
  configs=(${(o)configs})

  if [[ ${#configs[@]} -eq 0 ]]; then
    echo "$(colorize "[ERROR] Файлы конфигов не найдены в $configs_dir" "$C_RED")"
    exit 1
  fi

  echo "$(colorize "[OK] curl найден" "$C_GREEN")"

  echo ""
  echo "$(colorize "============================================================" "$C_CYAN")"
  echo "$(colorize "                 ТЕСТЫ КОНФИГОВ ZAPRET" "$C_CYAN")"
  printf "%s\n" "$(colorize "                 Всего конфигов: $(printf '%2d' ${#configs[@]})" "$C_CYAN")"
  echo "$(colorize "============================================================" "$C_CYAN")"

  # Выбор типа теста
  echo ""
  echo "Выберите тип теста:"
  echo "  [1] Стандартные тесты (HTTP/ping)"
  echo "  [2] DPI checkers (TCP 16-20 freeze)"
  printf "Введите 1 или 2: "
  read -r test_type_choice

  # Выбор режима тестирования
  local mode
  mode=$(read_mode_selection)
  if [[ "$mode" == "select" ]]; then
    local selected_output
    selected_output=$(select_configs "${configs[@]}")
    configs=("${(@f)selected_output}")
  fi

  if [[ "$test_type_choice" != "1" && "$test_type_choice" != "2" ]]; then
    echo "$(colorize "[ERROR] Неверный выбор" "$C_RED")"
    exit 1
  fi

  local test_type
  [[ "$test_type_choice" == "1" ]] && test_type="standard" || test_type="dpi"

  # Инициализация логирования
  init_log "$log_dir" "$test_type"

  log_info "Тест запущен из: $root_dir"

  # Загрузка целей для стандартных тестов
  if [[ "$test_type" == "standard" ]]; then
    if [[ ! -f "$targets_file" ]]; then
      echo "$(colorize "[ERROR] targets.txt не найден" "$C_RED")"
      exit 1
    fi
  fi

  # Резервная копия текущего конфига
  if [[ -f "$zapret_config_backup" ]]; then
    log_warn "Резервная копия конфига уже существует, используется существующая"
  elif [[ -f "$zapret_config" ]]; then
    cp "$zapret_config" "$zapret_config_backup"
    log_ok "Текущий конфиг сохранён в $zapret_config_backup"
  fi

  # Для DPI тестов переключаем ipset в режим "any"
  local ipset_file="/opt/zapret/hostlists/ipset-all.txt"
  local ipset_backup="${ipset_file}.test-backup"
  local original_ipset_status=""

  if [[ "$test_type" == "dpi" ]]; then
    original_ipset_status=$(get_ipset_status "$ipset_file")
    if [[ "$original_ipset_status" != "any" ]]; then
      log_warn "Переключение ipset в режим 'any' для точных DPI тестов..."
      set_ipset_mode "any" "$ipset_file" "$ipset_backup"
      restart_zapret "$elevate_cmd"
      sleep 2
    fi
  fi

  # Запуск тестов для каждого конфига
  local idx=0
  local total=${#configs[@]}
  for config in "${configs[@]}"; do
    (( idx++ ))
    echo ""
    echo "$(colorize "------------------------------------------------------------" "$C_DARKCYAN")"
    echo "$(colorize "  [$idx/$total] $config" "$C_YELLOW")"
    echo "$(colorize "------------------------------------------------------------" "$C_DARKCYAN")"

    log_header "$idx" "$total" "$config"
    log_info "Тестирование конфига: $config"

    # Копирование конфига
    local source_config="$configs_dir/$config"
    if [[ ! -f "$source_config" ]]; then
      log_error "Файл конфига не найден: $source_config"
      continue
    fi

    cp "$source_config" "$zapret_config"
    log_info "Конфиг скопирован в $zapret_config"

    # Перезапуск zapret
    restart_zapret "$elevate_cmd"
    sleep 3

    if [[ "$test_type" == "standard" ]]; then
      run_standard_tests "$config" "$targets_file" "$DPI_TIMEOUT"
    else
      run_dpi_tests "$DPI_TIMEOUT" "$DPI_RANGE" "$DPI_WARN_MIN_KB" "$DPI_WARN_MAX_KB"
    fi

    [[ "$idx" -lt "$total" ]] && sleep 2
  done

  # Восстановление исходного конфига и ipset
  local need_restart=false

  if [[ -f "$zapret_config_backup" ]]; then
    mv "$zapret_config_backup" "$zapret_config"
    log_ok "Исходный конфиг восстановлен"
    need_restart=true
  fi

  if [[ "$test_type" == "dpi" && -n "$original_ipset_status" && "$original_ipset_status" != "any" ]]; then
    log_warn "Восстановление исходного режима ipset..."
    set_ipset_mode "restore" "$ipset_file" "$ipset_backup"
    log_ok "IPSet восстановлен в режим '$original_ipset_status'"
    need_restart=true
  fi

  if [[ "$need_restart" == true ]]; then
    restart_zapret "$elevate_cmd"
  fi

  echo ""
  log_ok "Тесты завершены"
  log_info "Файл лога сохранён в: $LOG_PATH"
  close_log
}

main "$@"
