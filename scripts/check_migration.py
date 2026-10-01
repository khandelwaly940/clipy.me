#!/usr/bin/env python3
"""Validate the production SQL migration on a disposable copy of a sealed backup."""
import argparse
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import time
import uuid
from migrate import TABLES, audit_database, table_digest, verify_backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backup', type=Path)
    args = parser.parse_args()
    baseline = verify_backup(args.backup)
    source = Path(__file__).resolve().parents[1]/'Clipy/Sources/ClipyMe/ClipyMeHistoryStore.swift'
    sql = re.search(r'static let migrationSQL = """\n(.*?)\n    """', source.read_text(), re.S).group(1)
    with tempfile.TemporaryDirectory(prefix='clipyme-migration-test-') as folder:
        target = Path(folder)/'sqlite.db'
        original = args.backup/'Application Support/sqlite.db'
        for suffix in ('', '-wal', '-shm'):
            if Path(str(original)+suffix).exists():
                shutil.copy2(Path(str(original)+suffix), Path(str(target)+suffix))
        db = sqlite3.connect(target)
        db.execute('PRAGMA foreign_keys=ON')
        db.create_function('uuid', 0, lambda: str(uuid.uuid4()))
        started = time.perf_counter()
        db.executescript(sql)
        elapsed = time.perf_counter()-started
        print(f'Index added {(target.stat().st_size-original.stat().st_size)/1024/1024:.1f} MiB.', flush=True)
        assert {table: table_digest(db, table) for table in TABLES} == baseline
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert not db.execute('PRAGMA foreign_key_check').fetchall()
        print(f'Migration preserved all original rows and asset bytes ({elapsed:.3f}s).')
        # Search must reach past Clipy's 10,001-character menu title limit.
        probe = 'clipyme-test-'+str(uuid.uuid4())
        text = ('x'*12000)+' needle punctuation "%_" café'
        db.execute('INSERT INTO pasteboardHistories(id,title,pasteboardTypes,updateAt) VALUES (?,?,?,?)',
                   (probe, text[:10001], '["public.utf8-plain-text"]', 42))
        db.execute('INSERT INTO pasteboardHistoryAssets(id,pasteboardHistoryID,"index",pasteboardType,data) VALUES (?,?,?,?,?)',
                   (str(uuid.uuid4()), probe, 0, 'public.utf8-plain-text', text.encode()))
        db.create_function('clipymeContains', 2, lambda text, term: term.casefold() in text.casefold(), deterministic=True)
        assert probe in [r[0] for r in db.execute('SELECT id FROM clipyMeFullText WHERE text LIKE ? AND text LIKE ?', ('%NEEDLE%', '%punctuation%'))]
        for query in ['CAFÉ', 'É', '"%_"']:
            assert probe in [r[0] for r in db.execute('SELECT id FROM clipyMeTextContent WHERE clipymeContains(text, ?)', (query,))]
        db.execute('UPDATE pasteboardHistoryAssets SET data=? WHERE pasteboardHistoryID=?', (b'needle revised text', probe))
        assert probe in [r[0] for r in db.execute('SELECT id FROM clipyMeFullText WHERE text LIKE ?', ('%revised%',))]
        assert probe not in [r[0] for r in db.execute('SELECT id FROM clipyMeFullText WHERE text LIKE ?', ('%punctuation%',))]
        db.execute("INSERT INTO clipyMeFullText(clipyMeFullText) VALUES('integrity-check')")
        db.execute('INSERT INTO clipyMeFavorites(historyID) VALUES (?)', (probe,))
        # Use the production pruning SQL, not a separately maintained copy.
        repository = source.parents[1]/'Repositories/PasteboardHistoryRepository.swift'
        pruning = re.search(r'try database.execute\(sql: """\n(.*?)\n\s+""", arguments: \[max\(0, maxHistorySize\)\]', repository.read_text(), re.S).group(1)
        db.execute(pruning, (0,))
        assert db.execute('SELECT id FROM pasteboardHistories').fetchall() == [(probe,)]
        db.execute('DELETE FROM pasteboardHistories WHERE id=?', (probe,))
        assert not db.execute('SELECT * FROM clipyMeFavorites').fetchall()
        assert not db.execute('SELECT id FROM clipyMeFullText WHERE id=?', (probe,)).fetchall()
        db.close()
        print('Passed: long-text search, case-insensitive search, Unicode, literal punctuation, favorite retention, cascading cleanup.')
    verify_backup(args.backup)


if __name__ == '__main__':
    main()
