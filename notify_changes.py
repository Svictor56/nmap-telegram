import sys
import requests
import re

# Укажите ваши данные
TOKEN = "API_TOCKEN"
CHAT_ID = "ID"


def send_message(file_path):
    with open(file_path, "r") as f:
        message = f.read()

    # Экранируем основные символы, требующие защиты в HTML
    message = message.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    payload = {
        "chat_id": CHAT_ID,
        "text": message,
        "parse_mode": "HTML"
    }

    response = requests.post(url, data=payload)
    if response.status_code == 200:
        print("Сообщение отправлено.")
    else:
        print("Ошибка при отправке сообщения:", response.text)

if __name__ == "__main__":
    send_message(sys.argv[1])
