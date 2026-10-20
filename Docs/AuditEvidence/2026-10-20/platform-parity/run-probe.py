import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description="Run the original five platform renderer probes on this Mac.")
parser.add_argument("platform", choices=("macos", "ipad"))
parser.add_argument("--source-root", type=Path, help="App/shared source folder to compile")
parser.add_argument("--output", type=Path, help="Directory for generated fixtures, logs and results")
args = parser.parse_args()
label = args.platform
repository = Path(__file__).resolve().parents[4]
source = args.source_root or (repository / "LightAudio Editor" if label == "macos"
                              else repository.parent / "LightAudio iPadOS/Shared")
out = args.output or Path(tempfile.mkdtemp(prefix="lae-parity-probe-"))
out.mkdir(parents=True, exist_ok=True)
files = [source / name for name in (
    "Models/Timeline.swift", "Models/Project.swift", "Models/MediaAsset.swift",
    "Utilities/AudioFormatHelpers.swift", "Services/TimelineRenderService.swift"
)]
(out / f"{label}-source-manifest.json").write_text(json.dumps({
    str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files
}, indent=2))
cmd = ["xcrun", "swiftc", "-module-cache-path", str(out / f"{label}-module-cache"),
       "-o", str(out / label), *(str(path) for path in files), str(Path(__file__).with_name("Probe.swift"))]
compilation = subprocess.run(cmd, text=True, capture_output=True)
(out / f"{label}-build.log").write_text(compilation.stdout + compilation.stderr)
if compilation.returncode:
    print(compilation.stdout + compilation.stderr)
    sys.exit(compilation.returncode)
probe = subprocess.run([str(out / label), str(out / f"{label}-fixtures")], text=True, capture_output=True)
(out / f"{label}-results.json").write_text(probe.stdout)
(out / f"{label}-run.log").write_text(probe.stderr)
print(label, probe.stdout, probe.stderr)
print("Evidence:", out)
sys.exit(probe.returncode)
