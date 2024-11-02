# nmap-telegram
Network Scanner with Change Detection and Telegram Notifications
# Network Scanner with Change Detection and Telegram Notifications

This project includes two scripts:

1. **`scan.sh`**: A Bash script that scans IP addresses or networks (from a file) for open ports using `masscan` and `nmap`. It saves scan results in an SQLite database and compares them to previous scans to detect changes (e.g., open or closed ports, new hosts).
2. **`notify_changes.py`**: A Python script that sends a notification to a Telegram channel about any detected changes in open ports or hosts.

## Bash Script: `scan.sh`

The Bash script performs the following steps:
1. Reads IP addresses and networks from a target file.
2. Uses `masscan` for a quick scan.
3. Runs `nmap` on open ports found by `masscan` for detailed information.
4. Logs results in an SQLite database, noting changes since the last scan.
5. Runs daily at night via cron.

### `scan.sh` Script

```bash
#!/bin/bash

# Parameters
TARGET_FILE="targets.txt"            # File with IPs or networks for scanning
DB_FILE="scan_results.db"            # Database file for storing results
TELEGRAM_SCRIPT="notify_changes.py"  # Python script for notifications

# Check for target file existence
if [[ ! -f "$TARGET_FILE" ]]; then
  echo "Target file not found!"
  exit 1
fi

# Create database if it doesn't exist
if [[ ! -f "$DB_FILE" ]]; then
  sqlite3 "$DB_FILE" <<EOF
CREATE TABLE scan_results (
  ip TEXT,
  port INTEGER,
  status TEXT,
  service TEXT,
  timestamp TEXT,
  PRIMARY KEY (ip, port)
);
EOF
fi

# Function to save data to database
save_to_db() {
  local ip=$1
  local port=$2
  local status=$3
  local service=$4
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  sqlite3 "$DB_FILE" <<EOF
REPLACE INTO scan_results (ip, port, status, service, timestamp)
VALUES ('$ip', $port, '$status', '$service', '$timestamp');
EOF
}

# Function to compare current data with previous data
compare_and_notify() {
  local ip=$1
  local port=$2
  local new_status=$3

  # Check if this IP and port was in the database and its status
  prev_status=$(sqlite3 "$DB_FILE" "SELECT status FROM scan_results WHERE ip='$ip' AND port=$port;")
  
  if [[ "$prev_status" != "$new_status" ]]; then
    echo "Change detected: $ip:$port $prev_status -> $new_status" >> changes.log
  fi
}

# Run masscan for quick scanning
echo "Running masscan for quick scan..."
masscan -p1-65535 -iL "$TARGET_FILE" --rate=10000 | while read -r line; do
  ip=$(echo "$line" | awk '{print $6}')
  port=$(echo "$line" | awk '{print $4}' | cut -d '/' -f 1)
  
  # Run nmap for detailed scanning
  echo "Scanning $ip:$port using nmap..."
  nmap -p "$port" -sV "$ip" -oG - | grep -Eo "([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|open|closed|filtered|SERVICE)" | while read -r nmap_result; do
    service=$(echo "$nmap_result" | awk '{print $3}')
    status=$(echo "$nmap_result" | awk '{print $2}')
    
    # Compare with previous data
    compare_and_notify "$ip" "$port" "$status"

    # Save to database
    save_to_db "$ip" "$port" "$status" "$service"
  done
done

# Run notification script if changes are detected
if [[ -f changes.log ]]; then
  echo "Sending notifications about detected changes..."
  python3 "$TELEGRAM_SCRIPT"
  rm changes.log
fi
