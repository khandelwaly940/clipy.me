#!/usr/bin/env python3
"""Back up and stage Clipy 1.3.0 without changing the installed app or its data.

Usage: python3 scripts/migrate.py backup
       python3 scripts/migrate.py stage BACKUP_DIRECTORY
       python3 scripts/migrate.py verify BACKUP_DIRECTORY
Stage refuses to overwrite any existing ClipyMe installation data.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time

ORIGINAL_ID = 'com.clipy-app.Clipy'
CUSTOM_ID = 'local.clipyme.app'
TABLES = ('pasteboardHistories', 'pasteboardHistoryAssets',
          'pasteboardHistoryThumbnailAssets', 'snippets', 'snippetFolders')


def run(*args):
    return subprocess.run(args, check=True, capture_output=True)


def ignore_special(directory, names):
    return [n for n in names if not (stat.S_ISREG((Path(directory)/n).lstat().st_mode)
                                   or stat.S_ISDIR((Path(directory)/n).lstat().st_mode)
                                   or stat.S_ISLNK((Path(directory)/n).lstat().st_mode))]


def copy_tree(source, destination):
    if source.exists():
        shutil.copytree(source, destination, symlinks=True, ignore=ignore_special)


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def table_digest(connection, table):
    # Hash every original column, including asset bytes; never emit clipboard content.
    hasher = hashlib.sha256()
    count = 0
    columns = connection.execute(f'PRAGMA table_info("{table}")').fetchall()
    order = ','.join('"'+column[1]+'"' for column in columns if column[5])
    if not order:
        raise RuntimeError(f'Missing primary key in {table}')
    for row in connection.execute(f'SELECT * FROM "{table}" ORDER BY {order}'):
        count += 1
        for value in row:
            data = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
            hasher.update(type(value).__name__.encode())
            hasher.update(len(data).to_bytes(8, 'big'))
            hasher.update(data)
    return {'count': count, 'sha256': hasher.hexdigest()}


def audit_database(path):
    # Inspect a disposable copy so SQLite cannot checkpoint or touch a sealed backup.
    with tempfile.TemporaryDirectory(prefix='clipyme-audit-') as directory:
        temporary = Path(directory)/'sqlite.db'
        for suffix in ('', '-wal', '-shm'):
            source = Path(str(path)+suffix)
            if source.exists():
                shutil.copy2(source, Path(str(temporary)+suffix))
        connection = sqlite3.connect(temporary)
        try:
            if connection.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise RuntimeError('Database integrity check failed')
            if connection.execute('PRAGMA foreign_key_check').fetchall():
                raise RuntimeError('Database foreign-key check failed')
            return {table: table_digest(connection, table) for table in TABLES}
        finally:
            connection.close()


def verify_backup(root):
    manifest = json.loads((root/'manifest.json').read_text())
    for name, expected in manifest.items():
        if digest(root/name) != expected:
            raise RuntimeError(f'Backup checksum mismatch: {name}')
    expected = json.loads((root/'database-audit.json').read_text())
    if audit_database(root/'Application Support/sqlite.db') != expected:
        raise RuntimeError('Backup database does not match its recorded audit')
    print('Verified every backup file and every original database row.')
    return expected


def backup(reopen=True):
    home = Path.home()
    root = home/'Library/Application Support/ClipyMe Backups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    root.mkdir(parents=True, mode=0o700)
    running = subprocess.run(['pgrep', '-f', '^/Applications/Clipy.app/Contents/MacOS/Clipy$'], capture_output=True).returncode == 0
    if running:
        run('osascript', '-e', 'tell application "Clipy" to quit')
        for _ in range(100):
            if subprocess.run(['pgrep', '-f', '^/Applications/Clipy.app/Contents/MacOS/Clipy$'], capture_output=True).returncode != 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Clipy has not exited; no live database files were copied')
    try:
        run('defaults', 'export', ORIGINAL_ID, str(root/'preferences.plist'))
        copy_tree(home/'Library/Application Support'/ORIGINAL_ID, root/'Application Support')
        copy_tree(home/'Library/Caches'/ORIGINAL_ID, root/'Caches')
        # Retain older storage too if it is still present.
        copy_tree(home/'Library/Application Support/Clipy', root/'Legacy Support')
        copy_tree(home/'Library/Saved Application State'/(ORIGINAL_ID+'.savedState'), root/'Saved State')
        copy_tree(Path('/Applications/Clipy.app'), root/'Clipy.app')
        source = home/'Library/Preferences'/(ORIGINAL_ID+'.plist')
        if source.exists():
            shutil.copy2(source, root/'original-preferences.plist')
        audit = audit_database(root/'Application Support/sqlite.db')
        (root/'database-audit.json').write_text(json.dumps(audit, indent=2))
        manifest = {str(p.relative_to(root)): digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
        (root/'manifest.json').write_text(json.dumps(manifest, indent=2))
        verify_backup(root)
        print(root)
        print('History entries:', audit['pasteboardHistories']['count'])
    finally:
        if running and reopen:
            run('open', '/Applications/Clipy.app')
    return root


def stage(root):
    audit = verify_backup(root)
    home = Path.home()
    support = home/'Library/Application Support'/CUSTOM_ID
    preferences = home/'Library/Preferences'/(CUSTOM_ID+'.plist')
    if support.exists() or preferences.exists() or subprocess.run(
            ['defaults', 'read', CUSTOM_ID], capture_output=True).returncode == 0:
        raise RuntimeError('ClipyMe data already exists. Refusing to overwrite it.')
    # Copy into a staging directory, validate everything, then atomically publish it.
    with tempfile.TemporaryDirectory(prefix='.clipyme-stage-', dir=support.parent) as directory:
        candidate = Path(directory)/CUSTOM_ID
        copy_tree(root/'Application Support', candidate)
        if audit_database(candidate/'sqlite.db') != audit:
            raise RuntimeError('Staged database differs from original')
        expected_preferences = plistlib.loads((root/'preferences.plist').read_bytes())
        try:
            run('defaults', 'import', CUSTOM_ID, str(root/'preferences.plist'))
            # Export to a file: stdout uses XML and truncates fractional date
            # seconds, making a preserved updater timestamp appear different.
            exported_path = Path(directory)/'verified-preferences.plist'
            run('defaults', 'export', CUSTOM_ID, str(exported_path))
            if plistlib.loads(exported_path.read_bytes()) != expected_preferences:
                raise RuntimeError('Staged preferences differ from original; application was not installed')
            os.rename(candidate, support)
        except Exception:
            # The destination was proven absent above. Undo only this new preference domain.
            subprocess.run(['defaults', 'delete', CUSTOM_ID], capture_output=True)
            if preferences.exists() and not plistlib.loads(preferences.read_bytes()):
                preferences.unlink()
            raise
    print('Staged and verified all clipboard assets and preferences:', support)
    print('Original app, login item and storage are unchanged.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('backup', 'verify', 'stage'))
    parser.add_argument('backup_directory', nargs='?', type=Path)
    parser.add_argument('--keep-stopped', action='store_true', help='Leave original Clipy stopped for an immediate switch')
    args = parser.parse_args()
    if args.command == 'backup':
        backup(reopen=not args.keep_stopped)
    else:
        if args.backup_directory is None:
            parser.error('backup_directory is required')
        (stage if args.command == 'stage' else verify_backup)(args.backup_directory.resolve())


if __name__ == '__main__':
    main()
