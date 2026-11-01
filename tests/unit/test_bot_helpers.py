"""Unit tests for pure helpers in scripts/telegram_bot.py.

The bot imports the telegram SDK at module load, so the SDK is stubbed here.
Only helpers that do not touch the network are tested.
"""

import importlib
import sys
import types
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))


def _stub(name: str, **attrs: object) -> None:
    module = types.ModuleType(name)
    module.__dict__.update(attrs)
    sys.modules.setdefault(name, module)


class _Any:
    def __init__(self, *args: object, **kwargs: object) -> None:
        pass


_stub(
    "env_loader", load_env=lambda path: None
)  # bot loads scripts/.env at import; CI has none
_stub("telegram", Update=_Any)
_stub("telegram.error", NetworkError=Exception)
_stub(
    "telegram.ext",
    ApplicationBuilder=_Any,
    CommandHandler=_Any,
    # Handler annotations are evaluated at import on Python < 3.14, so DEFAULT_TYPE must exist.
    ContextTypes=types.SimpleNamespace(DEFAULT_TYPE=object),
)

bot = importlib.import_module("telegram_bot")


def test_format_backup_name_splits_timestamp() -> None:
    assert (
        bot.format_backup_name("DreamSeed_prod_2026-11-01_12-30.tar.gz")
        == "prod_2026-11-01 12:30"
    )


def test_format_backup_name_without_timestamp_is_returned_stripped() -> None:
    assert bot.format_backup_name("DreamSeed_notes.tar.gz") == "notes"


def test_get_size_formats_megabytes_and_kilobytes() -> None:
    assert bot.get_size(2 * 1048576) == "2MB"
    assert bot.get_size(4096) == "4KB"


def test_get_size_empty_and_missing_file() -> None:
    assert bot.get_size("") == "-"
    assert bot.get_size("/nonexistent/path/backup.tar.gz") == "-"
