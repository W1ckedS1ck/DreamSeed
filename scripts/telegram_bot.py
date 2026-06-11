#!/usr/bin/env python3

import logging
import os
import sys
import time
import subprocess
import threading
import requests
from http.server import HTTPServer, BaseHTTPRequestHandler

from env_loader import load_env

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    stream=sys.stdout,
)
log = logging.getLogger('dreamseed-bot')

HEALTH_PORT = 8553

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(SCRIPT_DIR, '.env')

load_env(ENV_FILE)

TG_TOKEN = os.environ.get('TG_TOKEN', '')
TG_CHAT_ID = os.environ.get('TG_CHAT_ID', '')
TG_THREAD_STR = os.environ.get('TG_THREAD_ID', '').strip()
TG_THREAD_ID = int(TG_THREAD_STR) if TG_THREAD_STR.isdigit() else None

BACKUP_DIR = os.environ.get('BACKUP_DIR', '/home/ubuntu/backups')
RCLONE_REMOTE = 'gdrive'
REMOTE_BASE = os.environ.get('REMOTE_BASE', 'DreamSeed/backups')
BOT_USERNAME = os.environ.get('BOT_USERNAME', 'DreamSeedOnline_bot')
DB_PREFIX = os.environ.get('DB_PREFIX', 'db_modx_db_')


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        log.debug("health: %s", format % args)


def start_health_server():
    try:
        server = HTTPServer(('127.0.0.1', HEALTH_PORT), HealthHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        log.info("Health endpoint listening on http://127.0.0.1:%d/health", HEALTH_PORT)
    except Exception as e:
        log.warning("Health endpoint failed to start: %s", e)


def get_size(filepath_or_bytes):
    if not filepath_or_bytes:
        return "-"
    try:
        if isinstance(filepath_or_bytes, str) and not filepath_or_bytes.isdigit():
            size = os.path.getsize(filepath_or_bytes)
        else:
            size = int(filepath_or_bytes)
        if size > 1048576:
            return f"{size // 1048576}MB"
        else:
            return f"{size // 1024}KB"
    except Exception as e:
        log.warning("Failed to get file size: %s", e)
        return "-"

def get_env():
    env = os.environ.get('ENV', '')
    if env:
        return env
    hostname = subprocess.check_output(['hostname'], text=True).strip()
    if 'prod' in hostname:
        return "prod"
    return "dev"

def format_backup_name(filename, prefix='DreamSeed_'):
    name = filename.replace(prefix, '').replace('.tar.gz', '').replace('.sql.gz', '')
    parts = name.rsplit('_', 1)
    if len(parts) == 2:
        return f"{parts[0]} {parts[1].replace('-', ':')}"
    return name

def _local_backups(subdir, prefix):
    path = f'{BACKUP_DIR}/{subdir}'
    try:
        return sorted(
            [f for f in os.listdir(path) if f.startswith(prefix)],
            key=lambda x: os.path.getmtime(f'{path}/{x}'), reverse=True
        )
    except Exception as e:
        log.warning("Failed to list local backups in %s: %s", path, e)
        return []

def _rclone_lsf(path):
    try:
        out = subprocess.check_output(
            ['rclone', 'lsf', path, '--files-only', '--format', 'tps'],
            text=True, timeout=30
        ).strip()
        return sorted(
            [line.split(';', 2) for line in out.split('\n') if line],
            key=lambda x: x[0], reverse=True
        )
    except Exception as e:
        log.warning("rclone lsf %s failed: %s", path, e)
        return []

def cmd_status():
    env = get_env()
    try:
        proj_files = _local_backups('project', 'DreamSeed_')
        db_files = _local_backups('db', 'db_')

        env_suffix = "" if env == "prod" else f"-{env}"
        cloud_proj_files = _rclone_lsf(f'{RCLONE_REMOTE}:{REMOTE_BASE}/project{env_suffix}/')
        cloud_db_files = _rclone_lsf(f'{RCLONE_REMOTE}:{REMOTE_BASE}/db{env_suffix}/')

        def cloud_size(size_bytes):
            try:
                s = int(size_bytes)
                if s > 1048576:
                    return f"{s // 1048576}MB"
                else:
                    return f"{s // 1024}KB"
            except Exception as e:
                log.warning("Failed to parse cloud size %s: %s", size_bytes, e)
                return "-"

        msg = f"📊 <b>Backup Status</b> — {env}\n\n"

        msg += "📁 Local:\n"
        for f in proj_files[:2]:
            msg += f"  🖥 {format_backup_name(f)} ({get_size(f'{BACKUP_DIR}/project/{f}')})\n"
        for f in db_files[:2]:
            msg += f"  🗄 {format_backup_name(f, DB_PREFIX)} ({get_size(f'{BACKUP_DIR}/db/{f}')})\n"

        msg += "\n☁️ GDrive:\n"
        for line in cloud_proj_files[:2]:
            msg += f"  🖥 {format_backup_name(line[1])} ({cloud_size(line[2])})\n"
        for line in cloud_db_files[:2]:
            msg += f"  🗄 {format_backup_name(line[1], DB_PREFIX)} ({cloud_size(line[2])})\n"

        msg += f"\n⏰ Last check: {time.strftime('%d.%m %H:%M')}"
        return msg
    except Exception as e:
        return f"Error: {e}"

def cmd_backups():
    env = get_env()
    try:
        proj_files = _local_backups('project', 'DreamSeed_')[:5]
        db_files = _local_backups('db', 'db_')[:5]

        msg = f"🖥 <b>Last 5 Projects</b> — {env}\n\n"
        msg += '\n'.join([f"{format_backup_name(f)} ({get_size(f'{BACKUP_DIR}/project/{f}')})" for f in proj_files])

        msg += f"\n\n🗄 <b>Last 5 DB</b> — {env}\n\n"
        msg += '\n'.join([f"{format_backup_name(f, DB_PREFIX)} ({get_size(f'{BACKUP_DIR}/db/{f}')})" for f in db_files])

        return msg
    except Exception as e:
        return f"Error: {e}"

def main():
    if not TG_TOKEN:
        log.error("TG_TOKEN not set")
        return

    start_health_server()

    last_update = None
    commands = {
        '/status': cmd_status,
        '/backups': cmd_backups,
        '/backup': cmd_backups,
    }

    retry_count = 0

    while True:
        try:
            params = {'timeout': 30}
            if last_update is not None:
                params['offset'] = last_update

            updates = requests.get(f'https://api.telegram.org/bot{TG_TOKEN}/getUpdates',
                               params=params, timeout=35).json()

            if updates.get('ok') and updates.get('result'):
                for up in updates.get('result', []):
                    last_update = up['update_id'] + 1

                    if 'message' in up:
                        msg = up['message']
                        chat_id = str(msg['chat']['id'])

                        if chat_id != TG_CHAT_ID:
                            log.warning("Ignored message from unauthorized chat: %s", chat_id)
                            continue

                        # Ignore replies to the bot's own messages
                        if 'reply_to_message' in msg:
                            reply_from = msg['reply_to_message'].get('from', {})
                            if reply_from.get('is_bot', False):
                                continue

                        text = msg.get('text', '')
                        command_text = text.split('@')[0]
                        entities = msg.get('entities', [])
                        for entity in entities:
                            if entity.get('type') == 'bot_command':
                                entity_text = text[entity['offset']:entity['offset'] + entity['length']]
                                command_text = entity_text.split('@')[0]
                                break

                        handler = commands.get(command_text)
                        t0 = time.time()
                        if handler:
                            response = handler()
                            elapsed = time.time() - t0
                            response += f"\n\n⏱ {elapsed:.1f}s"
                        else:
                            response = "Use /status or /backups"

                        send_kwargs = {'chat_id': chat_id, 'text': response, 'parse_mode': 'HTML'}
                        if TG_THREAD_ID is not None:
                            send_kwargs['message_thread_id'] = TG_THREAD_ID

                        resp = requests.post(f'https://api.telegram.org/bot{TG_TOKEN}/sendMessage',
                                  json=send_kwargs)
                        if resp.status_code == 429:
                            retry_after = resp.json().get('parameters', {}).get('retry_after', 5)
                            log.warning("Telegram 429 rate limit, retrying after %ds", retry_after)
                            time.sleep(retry_after)
                            resp = requests.post(f'https://api.telegram.org/bot{TG_TOKEN}/sendMessage',
                                      json=send_kwargs)
                        if not resp.json().get('ok'):
                            log.warning("Telegram API error: %s", resp.text)

            retry_count = 0
            time.sleep(1)

        except requests.exceptions.Timeout:
            retry_count += 1
            backoff = min(2 ** retry_count, 300)
            log.warning("Timeout (retry %d), sleeping %ds", retry_count, backoff)
            time.sleep(backoff)
        except Exception as e:
            log.error("Main loop error: %s", e)
            retry_count += 1
            time.sleep(min(2 ** retry_count, 300))

if __name__ == '__main__':
    main()
