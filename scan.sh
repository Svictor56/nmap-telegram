#!/bin/bash

# Параметры
TARGET_FILE="targets.txt"
DB_FILE="scan_results.db"
TELEGRAM_SCRIPT="notify_changes.py"
LOG_DIR="scan_history"
CURRENT_DATE=$(date +"%Y-%m-%d")
LOG_FILE="$LOG_DIR/scan_log_$CURRENT_DATE.txt"
TEMP_PORTS_FILE="temp_ports.txt"
TEMP_MESSAGE_FILE="temp_message.txt"

# Логирование
log() {
  local message="$1"
  echo "$(date +"%Y-%m-%d %H:%M:%S") - $message" | tee -a "$LOG_FILE"
}

# Проверка наличия команд
for cmd in masscan nmap sqlite3 xmllint; do
  command -v $cmd >/dev/null 2>&1 || { echo >&2 "$cmd не найден. Установите $cmd."; exit 1; }
done

# Создаём LOG_DIR, если не существует
mkdir -p "$LOG_DIR"

# Чтение целей
TARGETS=()
if [[ -s "$TARGET_FILE" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && TARGETS+=("$line")
  done < "$TARGET_FILE"
else
  log "Файл $TARGET_FILE пуст или отсутствует."
  exit 1
fi

# Создание БД
if [[ ! -f "$DB_FILE" ]]; then
  sqlite3 "$DB_FILE" <<EOF
CREATE TABLE scan_results (ip TEXT, port INTEGER, status TEXT, service TEXT, hostname TEXT, mac_address TEXT, timestamp TEXT, PRIMARY KEY (ip, port));
CREATE TABLE scan_history (ip TEXT, port INTEGER, status TEXT, service TEXT, hostname TEXT, mac_address TEXT, timestamp TEXT);
EOF
fi

# Функции для работы с БД
save_to_db() {
  local ip=$1 port=$2 status=$3 service=$4 hostname=$5 mac_address=$6
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  sqlite3 "$DB_FILE" <<EOF
REPLACE INTO scan_results (ip, port, status, service, hostname, mac_address, timestamp)
VALUES ('$ip', $port, '$status', '$service', '$hostname', '$mac_address', '$timestamp');
EOF
}

save_to_history() {
  local ip=$1 port=$2 status=$3 service=$4 hostname=$5 mac_address=$6
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  sqlite3 "$DB_FILE" <<EOF
INSERT INTO scan_history (ip, port, status, service, hostname, mac_address, timestamp)
VALUES ('$ip', $port, '$status', '$service', '$hostname', '$mac_address', '$timestamp');
EOF
}

get_previous_status() {
  local ip=$1 port=$2
  sqlite3 "$DB_FILE" "SELECT status FROM scan_results WHERE ip='$ip' AND port=$port;"
}

# Функция для отправки уведомлений о изменениях
notify_change() {
  local message=$1
  # Убираем теги <br> и используем \n для переноса строк
  message=$(echo -e "$message" | sed 's/<br>/\n/g')
  python3 "$TELEGRAM_SCRIPT" "$message"
}

# Сканирование и обработка результатов
for ip in "${TARGETS[@]}"; do
  masscan_command="masscan -p1-65535 $ip --rate=10000"
  log "Запущенная команда masscan: $masscan_command"
  eval "$masscan_command" > "$TEMP_PORTS_FILE" 2>>"$LOG_FILE"

  declare -A ip_open_ports
  ports=""

  while read -r line; do
    if [[ $line =~ Discovered\ open\ port\ ([0-9]+)/tcp\ on\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      port="${BASH_REMATCH[1]}"
      ip="${BASH_REMATCH[2]}"
      log "Обработка IP: $ip с найденным портом: $port"
      ip_open_ports["$ip"]+="$port "
      ports+="$port,"
    fi
  done < "$TEMP_PORTS_FILE"

  ports=${ports%,}
  rm -f "$TEMP_PORTS_FILE"

  if [[ -n "$ports" ]]; then
      scan_date=$(date +"%Y-%m-%d_%H-%M-%S")
      xml_output_file="$LOG_DIR/nmap_scan_${ip}_${scan_date}.xml"
      nmap_command="nmap -p $ports -sV -oX $xml_output_file $ip"
      log "Запуск команды nmap: $nmap_command"
      eval "$nmap_command" 2>>"$LOG_FILE"

      if [[ ! -s "$xml_output_file" ]]; then
        log "Файл с результатами nmap пуст. Пропуск анализа для $ip."
        continue
      fi

      # Извлечение имени хоста из XML-файла
      host_info=$(xmllint --xpath 'string(/nmaprun/host/hostnames/hostname/@name)' "$xml_output_file" 2>/dev/null)
      mac_address=$(xmllint --xpath 'string(/nmaprun/host/address[@addrtype="mac"]/@addr)' "$xml_output_file" 2>/dev/null)

      open_ports_message=""
      changes=""

      # Извлечение информации об открытых портах
      while read -r line; do
        port=$(xmllint --xpath 'string(//port[state/@state="open"]/@portid)' - <<<"$line" 2>/dev/null)
        service=$(xmllint --xpath 'string(//port[state/@state="open"]/service/@name)' - <<<"$line" 2>/dev/null)

        if [[ -n "$service" ]]; then
          previous_status=$(get_previous_status "$ip" "$port")
          if [[ -z "$previous_status" ]]; then
            open_ports_message+="Порт: $port, Сервис: $service - open\n"
            changes+="  \nНовый порт: $port ($service) - open"
          elif [[ "$previous_status" != "open" ]]; then
            changes+="  \nПорт $port ($service) изменился: $previous_status -> open"
          fi

          save_to_db "$ip" "$port" "open" "$service" "$host_info" "$mac_address"
          save_to_history "$ip" "$port" "open" "$service" "$host_info" "$mac_address"
        fi
      done < "$xml_output_file"

      # Подготовка сообщения с использованием временного файла
      echo -e "Сканирование $host_info $ip завершено.  \n" > "$TEMP_MESSAGE_FILE"
      #if [[ -n "$open_ports_message" ]]; then
      #  echo -e "Открытые порты:\n$open_ports_message" >> "$TEMP_MESSAGE_FILE"
      #fi
      if [[ -n "$changes" ]]; then
        echo -e "Изменения:  \n$changes" >> "$TEMP_MESSAGE_FILE"
      fi

      # Отправка уведомления, если есть изменения или хост новый
      if [[ -n "$changes" || $(is_new_host "$ip") -eq 0 ]]; then
        python3 "$TELEGRAM_SCRIPT" "$TEMP_MESSAGE_FILE"
        log "Отправлено уведомление в Telegram для $ip"
      else
        log "Нет изменений для хоста $ip."
      fi
  fi
done

# Корректная архивация старых логов
find "$LOG_DIR" -type f -mtime +30 -name "*.txt" -exec mv {} "{}_$(date +"%Y-%m")" \;

echo "Сканирование завершено." | tee -a "$LOG_FILE"
rm -f "$TEMP_MESSAGE_FILE"
