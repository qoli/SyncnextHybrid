#!/usr/bin/env python3
"""Generate playable, extensionless ISO9660 and UDF DVD fixtures for 0008 retirement."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("An installed ffmpeg with MPEG-2 and AC-3 encoders is required")
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "testsrc2=size=640x360:rate=24:duration=45", "-f", "lavfi", "-i",
        "sine=frequency=440:sample_rate=48000:duration=45", "-c:v", "mpeg2video",
        "-q:v", "4", "-g", "12", "-c:a", "ac3", "-b:a", "192k", "-f", "vob",
        str(output / "title.vob"),
    ], check=True)
    with tempfile.TemporaryDirectory(prefix="disc-fixture-build-") as temporary:
        build = Path(temporary)
        helpers = [ROOT / "Tests/UpstreamDiscRetirement/ISO9660Fixture.swift",
                   ROOT / "AetherEngine/Tests/AetherEngineTests/UDFFixture.swift"]
        for source in helpers:
            (build / source.name).write_text(source.read_text().replace("@testable import AetherEngine\n", ""))
        (build / "main.swift").write_text('''import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let title = try Data(contentsOf: output.appendingPathComponent("title.vob"))
let sector = ISO9660Fixture.sectorSize
var iso = ISO9660Fixture.make(files: [
    .init(name: "VTS_01_1.VOB", length: title.count, content: Array(title.prefix(sector)))
], firstFileLBA: 2048)
iso.append(title.dropFirst(sector))
while iso.count % sector != 0 { iso.append(0) }
iso.replaceSubrange((16 * sector + 80)..<(16 * sector + 88),
                    with: ISO9660Fixture.both32(iso.count / sector))
try iso.write(to: output.appendingPathComponent("opaque-dvd"))
var udf = UDFFixture.makeDVD(files: [(name: "VTS_01_1.VOB", bytes: Array(title))],
                            fragmented: ["VTS_01_1.VOB"])
for (index, identifier) in ["BEA01", "NSR03", "TEA01"].enumerated() {
    let offset = (16 + index) * sector
    udf.replaceSubrange(offset..<(offset + 7), with: [0] + Array(identifier.utf8) + [1])
}
try udf.write(to: output.appendingPathComponent("opaque-udf"))
''')
        executable = build / "fixture-builder"
        subprocess.run(["xcrun", "swiftc", str(build / "ISO9660Fixture.swift"),
                        str(build / "UDFFixture.swift"), str(build / "main.swift"),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(output)], check=True)
    resources = {}
    for name in ["opaque-dvd", "opaque-udf"]:
        data = (output / name).read_bytes()
        resources[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    report = {"durationSeconds": 45, "resources": resources,
              "video": "MPEG-2 640x360 24fps", "audio": "AC-3 48kHz",
              "dvdTitleLBA": 2048, "udfTitleFragmented": True,
              "contentType": "application/octet-stream"}
    (output / "provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
