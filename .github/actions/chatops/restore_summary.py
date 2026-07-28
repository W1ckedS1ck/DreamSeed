#!/usr/bin/env python3
import sys


def main():
    args = dict(arg.split('=', 1) for arg in sys.argv[1:])

    status = args.get('status', 'failed')
    rto = args.get('restore_duration', 'N/A')
    rows = args.get('content_rows', '?')
    tables = args.get('table_count', '?')
    http = args.get('http_code', '?')
    backup_project = args.get('backup_project', '?')
    backup_db = args.get('backup_db', '?')
    gdrive = args.get('gdrive', 'N/A')
    disk = args.get('disk_usage', '?')
    memory = args.get('memory_pct', '?')
    ssl = args.get('ssl_status', 'N/A')
    session = args.get('session_handler', 'N/A')
    exporters = args.get('exporters', '?')
    hash_ok = args.get('hash_match', 'N/A')

    icon = "✅" if status == "success" else "❌"
    link = args.get('run_url', '#')

    summary = f"""<b>Weekly Restore Test</b> {icon}

<b>SRE Metrics</b>
⏱ RTO: {rto}
📦 RPO: backup age ≤1h
🔄 Restore: {rows} rows, {tables} tables, HTTP {http}

<b>Backup</b>
📁 Local: {backup_project} proj, {backup_db} db
☁️ GDrive: {gdrive}
🔒 Hash: {hash_ok}

<b>System</b>
💾 Memory: {memory}%
🖴 Disk: {disk}%
🔐 SSL: {ssl}
🗄 Sessions: {session}
📊 Exporters: {exporters}

<a href=\"{link}\">Details →</a>"""

    print(summary)


if __name__ == '__main__':
    main()
