#!/bin/bash
cd /home/ubuntu/Scripts || exit 1
. /home/ubuntu/Scripts/common_functions.sh
load_env /home/ubuntu/Scripts/.env
exec /usr/bin/python3 /home/ubuntu/Scripts/telegram_bot.py