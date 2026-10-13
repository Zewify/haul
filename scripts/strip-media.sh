#!/usr/bin/env bash
# Build phase for the Safari extension: in the store edition, removes the media sniffer and the webRequest
# permission from the copied extension, so the App Store build contains no video-grabbing code.
set -euo pipefail
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "${DERIVED_FILE_DIR}"
touch "${DERIVED_FILE_DIR}/strip-media.stamp"
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
  *" DIRECT_EDITION "*) exit 0 ;;
esac
python3 - "$resources" <<'PY'
import json, os, sys
root = sys.argv[1]
manifest = os.path.join(root, "manifest.json")
data = json.load(open(manifest))
data["permissions"] = [p for p in data.get("permissions", []) if p != "webRequest"]
json.dump(data, open(manifest, "w"), indent=2)
media = os.path.join(root, "lib", "media.js")
if os.path.exists(media):
    open(media, "w").write("// Media grabbing is not part of this edition.\n(function (root) { root.HaulMedia = { classifyResponse: () => null, describeMedia: (i) => i.url, formatSize: () => '', normaliseMediaURL: (u) => u, findInPage: () => [] }; })(globalThis);\n")
PY
