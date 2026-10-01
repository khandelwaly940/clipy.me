#!/usr/bin/env python3
"""Developer tests; users need neither Python nor Xcode to run install.sh."""
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HELPER = str(Path(sys.argv.pop(1)).resolve())

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='clipyme-migration-test-')
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def run_helper(self, *args, success=True):
        result = subprocess.run([HELPER, *map(str,args)],capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
    def make_database(self, name):
        path=self.root/name
        with sqlite3.connect(path) as connection:
            connection.executescript('''
            CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES('Create initial tables');
            CREATE TABLE pasteboardHistories(id TEXT PRIMARY KEY,title TEXT,updateAt INTEGER);
            CREATE TABLE pasteboardHistoryAssets(id TEXT PRIMARY KEY,data BLOB);
            CREATE TABLE pasteboardHistoryThumbnailAssets(id TEXT PRIMARY KEY,data BLOB);
            CREATE TABLE snippets(id TEXT PRIMARY KEY,content TEXT);
            CREATE TABLE snippetFolders(id TEXT PRIMARY KEY,title TEXT);
            INSERT INTO pasteboardHistories VALUES('test','Synthetic clip',123);
            ''')
            connection.execute('INSERT INTO pasteboardHistoryAssets VALUES(?,?)',('asset',bytes(range(256))*4096))
        return path
    def test_database_copy_compares_every_blob_byte(self):
        before=self.make_database('before.db'); after=self.root/'after.db';shutil.copy2(before,after)
        self.run_helper('compare-db',before,after)
        with sqlite3.connect(after) as connection:
            connection.execute("UPDATE pasteboardHistoryAssets SET data=x'00'")
        self.run_helper('compare-db',before,after,success=False)
    def test_unknown_schema_is_refused(self):
        before=self.make_database('before.db')
        with sqlite3.connect(before) as connection:
            connection.execute("INSERT INTO grdb_migrations VALUES('Future incompatible schema')")
        self.run_helper('compare-db',before,before,success=False)
    def test_preferences_preserve_dates_and_archived_bytes(self):
        data={'date':datetime.datetime(2026,10,1,1,2,3,456789),'shortcut':b'\x00\xffarchive','enabled':False}
        first=self.root/'first.plist'; second=self.root/'second.plist'
        first.write_bytes(plistlib.dumps(data,fmt=plistlib.FMT_BINARY));shutil.copy2(first,second)
        self.run_helper('compare-plists',first,second)
        second.write_bytes(plistlib.dumps({**data,'enabled':True},fmt=plistlib.FMT_BINARY))
        self.run_helper('compare-plists',first,second,success=False)
    def test_copy_skips_fifo_and_refuses_overwrite(self):
        source=self.root/'source';source.mkdir();(source/'data').write_bytes(b'keep me');os.mkfifo(source/'realm.note')
        target=self.root/'copy';self.run_helper('copy-tree',source,target)
        self.assertEqual((target/'data').read_bytes(),b'keep me');self.assertFalse((target/'realm.note').exists())
        self.run_helper('copy-tree',source,target,success=False)
    def test_manifest_detects_corruption(self):
        folder=self.root/'backup';folder.mkdir();(folder/'data').write_bytes(b'original')
        self.run_helper('manifest',folder);self.run_helper('verify-manifest',folder)
        (folder/'data').write_bytes(b'changed')
        self.run_helper('verify-manifest',folder,success=False)

unittest.main()
