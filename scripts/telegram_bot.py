#!/usr/bin/env python3

import asyncio
import logging
import os
import socket
import sys
from datetime import datetime, timezone

from env_loader import load_env
from telegram import Update
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

log = logging.getLogger("dreamseed-bot")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
load_env(os.path.join(SCRIPT_DIR, ".env"))

TG_TOKEN = os.environ.get("TG_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")
TG_THREAD_STR = os.environ.get("TG_THREAD_ID", "").strip()
TG_THREAD_ID = int(TG_THREAD_STR) if TG_THREAD_STR.isdigit() else None

BACKUP_DIR = os.environ.get("BACKUP_DIR", "/home/ubuntu/backups")
RCLONE_REMOTE = os.environ.get("RCLONE_REMOTE", "gdrive-crypt")
REMOTE_BASE = os.environ.get("REMOTE_BASE", "DreamSeed/backups")
BOT_USERNAME = os.environ.get("BOT_USERNAME", "DreamSeedOnline_bot")
DB_PREFIX = os.environ.get("DB_PREFIX", "db_")


def _chat_allowed(update: Update) -> bool:
    if not TG_CHAT_ID:
        log.error("TG_CHAT_ID not set — all messages rejected")
        return False
    chat_id = str(update.effective_chat.id)
    if chat_id != TG_CHAT_ID:
        log.warning("Ignored message from unauthorized chat: %s", chat_id)
        return False
    msg = update.message
    return not (msg and msg.reply_to_message and msg.reply_to_message.from_user.is_bot)


def get_env() -> str:
    env = os.environ.get("ENV", "")
    if env:
        return "prod" if env == "prod" else "dev"
    return "prod" if "prod" in socket.gethostname() else "dev"


def format_backup_name(filename: str, prefix: str = "DreamSeed_") -> str:
    name = filename.replace(prefix, "").replace(".tar.gz", "").replace(".sql.gz", "")
    parts = name.rsplit("_", 1)
    if len(parts) == 2:
        return f"{parts[0]} {parts[1].replace('-', ':')}"
    return name


def get_size(filepath_or_bytes):
    if not filepath_or_bytes:
        return "-"
    try:
        if isinstance(filepath_or_bytes, str) and not filepath_or_bytes.isdigit():
            size = os.path.getsize(filepath_or_bytes)
        else:
            size = int(filepath_or_bytes)
        return f"{size // 1048576}MB" if size > 1048576 else f"{size // 1024}KB"
    except (OSError, ValueError):
        return "-"


def _local_backups(subdir: str, prefix: str) -> list:
    path = os.path.join(BACKUP_DIR, subdir)
    try:
        files = [f for f in os.listdir(path) if f.startswith(prefix)]
        return sorted(files, key=lambda x: os.path.getmtime(os.path.join(path, x)), reverse=True)
    except OSError:
        return []


async def _rclone_lsf(path: str) -> list:
    try:
        proc = await asyncio.create_subprocess_exec(
            "rclone", "lsf", path, "--files-only", "--format", "tps",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
        lines = [line.split(";", 2) for line in out.decode().strip().split("\n") if line]
        return sorted(lines, key=lambda x: x[1], reverse=True) if lines else []
    except (OSError, asyncio.TimeoutError, UnicodeDecodeError):
        return []


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not _chat_allowed(update):
        return

    env = get_env()
    proj_files = _local_backups("project", "DreamSeed_")
    db_files = _local_backups("db", "db_")

    env_suffix = "" if env == "prod" else f"-{env}"
    cloud_proj, cloud_db = await asyncio.gather(
        _rclone_lsf(f"{RCLONE_REMOTE}:{REMOTE_BASE}/project{env_suffix}/"),
        _rclone_lsf(f"{RCLONE_REMOTE}:{REMOTE_BASE}/db{env_suffix}/"),
    )

    msg = f"📊 <b>Backup Status</b> — {env}\n\n📁 Local:\n"
    for f in proj_files[:2]:
        msg += f"  🖥 {format_backup_name(f)} ({get_size(os.path.join(BACKUP_DIR, 'project', f))})\n"
    for f in db_files[:2]:
        msg += f"  🗄 {format_backup_name(f, DB_PREFIX)} ({get_size(os.path.join(BACKUP_DIR, 'db', f))})\n"
    msg += "\n☁️ GDrive:\n"
    for line in cloud_proj[:2]:
        msg += f"  🖥 {format_backup_name(line[1])} ({get_size(line[2])})\n"
    for line in cloud_db[:2]:
        msg += f"  🗄 {format_backup_name(line[1], DB_PREFIX)} ({get_size(line[2])})\n"
    msg += f"\n⏰ Last check: {datetime.now(timezone.utc).strftime('%d.%m %H:%M')}"

    await update.message.reply_text(msg, parse_mode="HTML")


async def cmd_backups(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not _chat_allowed(update):
        return

    env = get_env()
    proj_files = _local_backups("project", "DreamSeed_")[:5]
    db_files = _local_backups("db", "db_")[:5]

    msg = f"🖥 <b>Last 5 Projects</b> — {env}\n\n"
    msg += "\n".join(
        f"{format_backup_name(f)} ({get_size(os.path.join(BACKUP_DIR, 'project', f))})"
        for f in proj_files
    )
    msg += f"\n\n🗄 <b>Last 5 DB</b> — {env}\n\n"
    msg += "\n".join(
        f"{format_backup_name(f, DB_PREFIX)} ({get_size(os.path.join(BACKUP_DIR, 'db', f))})"
        for f in db_files
    )

    await update.message.reply_text(msg, parse_mode="HTML")


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not _chat_allowed(update):
        return
    await update.message.reply_text("Use /status or /backups")


def main() -> None:
    if not TG_TOKEN:
        log.error("TG_TOKEN not set")
        return
    if not TG_CHAT_ID:
        log.error("TG_CHAT_ID not set")
        return

    app = (
        ApplicationBuilder()
        .token(TG_TOKEN)
        .read_timeout(30)
        .write_timeout(10)
        .connect_timeout(10)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("backups", cmd_backups))
    app.add_handler(CommandHandler("backup", cmd_backups))

    log.info("Bot started (asyncio + python-telegram-bot)")
    app.run_polling(allowed_updates=["message"])


if __name__ == "__main__":
    main()
