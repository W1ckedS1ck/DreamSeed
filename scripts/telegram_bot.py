#!/usr/bin/env python3

import os
import sys
import time
import subprocess
import requests

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(SCRIPT_DIR, '.env')

def load_env():
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    value = value.strip('"').strip("'")
                    os.environ.setdefault(key, value)

load_env()

TG_TOKEN = os.environ.get('TG_TOKEN', '')
TG_CHAT_ID = os.environ.get('TG_CHAT_ID', '')
try:
    TG_THREAD_ID = int(os.environ.get('TG_THREAD_ID', ''))
except ValueError:
    TG_THREAD_ID = None

BACKUP_DIR = '/home/ubuntu/backups'
RCLONE_REMOTE = 'gdrive'
GDRIVE_BASE = os.environ.get('GDRIVE_BASE', 'DreamSeed/backups')
BOT_USERNAME = os.environ.get('BOT_USERNAME', 'DreamSeedOnline_bot')
DB_PREFIX = os.environ.get('DB_PREFIX', 'db_modx_db_')

def get_size(filepath):
    if not filepath:
        return "-"
    try:
        size = os.path.getsize(filepath)
        if size > 1048576:
            return f"{size // 1048576}MB"
        else:
            return f"{size // 1024}KB"
    except:
        return "-"

def get_env():
    hostname = subprocess.check_output(['hostname'], text=True).strip()
    if 'prod' in hostname and 'preprod' not in hostname:
        return "prod"
    return "preprod"

def format_proj_name(filename):
    name = filename.replace('DreamSeed_', '').replace('.tar.gz', '')
    parts = name.rsplit('_', 1)
    if len(parts) == 2:
        return f"{parts[0]} {parts[1].replace('-', ':')}"
    return name

def format_db_name(filename):
    name = filename.replace(DB_PREFIX, '').replace('.sql.gz', '')
    parts = name.rsplit('_', 1)
    if len(parts) == 2:
        return f"{parts[0]} {parts[1].replace('-', ':')}"
    return name

def cmd_status():
    env = get_env()
    try:
        proj_files = sorted([f for f in os.listdir(f'{BACKUP_DIR}/project') if f.startswith('DreamSeed_')], key=lambda x: os.path.getmtime(f'{BACKUP_DIR}/project/{x}'), reverse=True)
        db_files = sorted([f for f in os.listdir(f'{BACKUP_DIR}/db') if f.startswith('db_')], key=lambda x: os.path.getmtime(f'{BACKUP_DIR}/db/{x}'), reverse=True)

        remote_base = GDRIVE_BASE
        try:
            cloud_proj_out = subprocess.check_output(['rclone', 'lsf', f'{RCLONE_REMOTE}:{remote_base}/project-{env}/', '--files-only', '--format', 'tps'], text=True).strip()
            cloud_proj_files = [line.split(';') for line in cloud_proj_out.split('\n') if line]
        except:
            cloud_proj_files = []
        try:
            cloud_db_out = subprocess.check_output(['rclone', 'lsf', f'{RCLONE_REMOTE}:{remote_base}/db-{env}/', '--files-only', '--format', 'tps'], text=True).strip()
            cloud_db_files = [line.split(';') for line in cloud_db_out.split('\n') if line]
        except:
            cloud_db_files = []

        def cloud_size(size_bytes):
            try:
                s = int(size_bytes)
                if s > 1048576:
                    return f"{s // 1048576}MB"
                else:
                    return f"{s // 1024}KB"
            except:
                return "-"

        msg = f"📊 *Backup Status* — {env}\n\n"

        msg += f"📁 Local:\n"
        for f in proj_files[:2]:
            msg += f"  🖥 {format_proj_name(f)} ({get_size(f'{BACKUP_DIR}/project/{f}')})\n"
        for f in db_files[:2]:
            msg += f"  🗄 {format_db_name(f)} ({get_size(f'{BACKUP_DIR}/db/{f}')})\n"

        msg += f"\n☁️ GDrive:\n"
        for line in cloud_proj_files[:2]:
            msg += f"  🖥 {format_proj_name(line[1])} ({cloud_size(line[2])})\n"
        for line in cloud_db_files[:2]:
            msg += f"  🗄 {format_db_name(line[1])} ({cloud_size(line[2])})\n"

        msg += f"\n⏰ Last check: {time.strftime('%d.%m %H:%M')}"
        return msg
    except Exception as e:
        return f"Error: {e}"

def cmd_backups():
    env = get_env()
    try:
        proj_files = sorted([f for f in os.listdir(f'{BACKUP_DIR}/project') if f.startswith('DreamSeed_')], key=lambda x: os.path.getmtime(f'{BACKUP_DIR}/project/{x}'), reverse=True)[:5]
        db_files = sorted([f for f in os.listdir(f'{BACKUP_DIR}/db') if f.startswith('db_')], key=lambda x: os.path.getmtime(f'{BACKUP_DIR}/db/{x}'), reverse=True)[:5]

        msg = f"🖥 *Last 5 Projects* — {env}\n\n"
        msg += '\n'.join([f"{format_proj_name(f)} ({get_size(f'{BACKUP_DIR}/project/{f}')})" for f in proj_files])

        msg += f"\n\n🗄 *Last 5 DB* — {env}\n\n"
        msg += '\n'.join([f"{format_db_name(f)} ({get_size(f'{BACKUP_DIR}/db/{f}')})" for f in db_files])

        return msg
    except Exception as e:
        return f"Error: {e}"

def main():
    if not TG_TOKEN:
        print("TG_TOKEN not set")
        return

    last_update = None

    while True:
        try:
            params = {'timeout': 1}
            if last_update is not None:
                params['offset'] = last_update

            updates = requests.get(f'https://api.telegram.org/bot{TG_TOKEN}/getUpdates',
                               params=params).json()

            if updates.get('ok') and updates.get('result'):
                for up in updates.get('result', []):
                    last_update = up['update_id'] + 1

                    if 'message' in up:
                        msg = up['message']
                        text = msg.get('text', '').split('@')[0]
                        chat_id = msg['chat']['id']

                        if text in ['/status', f'/status@{BOT_USERNAME}']:
                            response = cmd_status()
                        elif text in ['/backups', '/backup']:
                            response = cmd_backups()
                        else:
                            response = "Use /status or /backups"

                        send_kwargs = {'chat_id': TG_CHAT_ID or chat_id, 'text': response, 'parse_mode': 'Markdown'}
                        if TG_THREAD_ID:
                            send_kwargs['message_thread_id'] = TG_THREAD_ID

                        requests.post(f'https://api.telegram.org/bot{TG_TOKEN}/sendMessage',
                                  json=send_kwargs)

        except Exception as e:
            print(f"Error: {e}")

        time.sleep(1)

if __name__ == '__main__':
    main()
