"""Run focused, non-destructive parity observations on synthetic media on macOS."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('platform', choices=('macos', 'ipad'))
parser.add_argument('--source-root', type=Path, help='Override app/shared source folder')
parser.add_argument('--mac-source-root', type=Path, help='macOS source folder, for encoder settings and inspector')
parser.add_argument('--output', type=Path, help='New output directory; must not already exist')
args = parser.parse_args()
repository = Path(__file__).resolve().parents[4]
mac = args.mac_source_root or repository / 'LightAudio Editor'
source = args.source_root or (mac if args.platform == 'macos' else repository.parent / 'LightAudio iPadOS/Shared')
if args.output:
    out = args.output
    out.mkdir(parents=True, exist_ok=False)
else:
    out = Path(tempfile.mkdtemp(prefix='lae-parity-round2-'))
files = [source / 'App/ProjectController.swift']
for folder in ('Models', 'Services', 'Utilities'):
    files.extend(sorted((source / folder).glob('*.swift')))
files.append(mac / ('UI/InspectorViewController.swift' if args.platform == 'macos' else 'Services/ExternalEncoderSettings.swift'))
(out / 'source-manifest.json').write_text(json.dumps({str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}, indent=2))
executable = out / args.platform
command = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'module-cache'), '-o', str(executable)]
if args.platform == 'macos':
    command += ['-D', 'MAC_AUDIT']
command += [str(path) for path in files] + [str(Path(__file__).with_name('Probe.swift'))]
build = subprocess.run(command, capture_output=True, text=True)
(out / 'build.log').write_text(build.stdout + build.stderr)
if build.returncode:
    print(build.stdout + build.stderr)
    sys.exit(build.returncode)
run = subprocess.run([str(executable), str(out / 'fixtures')], capture_output=True, text=True)
(out / 'results.json').write_text(run.stdout)
(out / 'run.log').write_text(run.stderr)
print(run.stdout)
print('Evidence:', out)
sys.exit(run.returncode)
