import re
import sys

manifest = sys.stdin.read()
for name in ("DATABASE_USERNAME", "VALKEY_USERNAME"):
    manifest = re.sub(
        rf"(?m)^([ \t]*)- name: {name}\n\1  value: [^\n]*\n",
        "",
        manifest,
    )
sys.stdout.write(manifest)
