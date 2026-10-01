#!/usr/bin/env python3
"""Sign a local ClipyMe build with the persistent identity in the login keychain.

Usage: python3 scripts/sign_local.py build/DerivedData/Build/Products/Release/ClipyMe.app
The private key stays in Keychain; it must never be committed to the repository.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
args = parser.parse_args()
app = args.app.resolve()
if app.name != 'ClipyMe.app' or not (app/'Contents/MacOS/ClipyMe').is_file():
    parser.error('Expected a built ClipyMe.app bundle')
subprocess.run(['codesign', '--force', '--sign', 'ClipyMe Local Signing',
                '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['codesign', '-d', '-r-', str(app)], check=True)
