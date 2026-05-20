#!/bin/bash
cd /home/ubuntu/Scripts || exit 1
source ./.env
exec /usr/bin/python3 /home/ubuntu/Scripts/telegram_bot.py