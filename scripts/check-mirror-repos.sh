#!/usr/bin/env bash
#
# Assert that every ECR repository scripts/mirror-images.sh pushes to is
# actually declared in envs/prod's ecr_repositories.
#
# These two lists live in different files and are edited at different times.
# When they drift, nothing fails until `make mirror` is halfway through pushing
# gigabytes and hits "The repository with name '...' does not exist" — after the
# infrastructure apply has already succeeded.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

python3 - <<'PY'
import re, sys

tf = open("terraform/envs/prod/variables.tf").read()
block = re.search(r'variable\s+"ecr_repositories".*?\n\}', tf, re.S)
declared = set(re.findall(r'^\s+"([a-z0-9/_.-]+)"\s+=', block.group(0), re.M)) if block else set()

script = open("scripts/mirror-images.sh").read()
used = set(re.findall(r'mirror_image\s+"[^"]+"\s*\\?\s*\n?\s*"([a-z0-9/_.-]+)"', script))
used |= set(re.findall(r'mirror_chart\s+"[^"]+"\s+"[^"]+"\s+"([a-z0-9/_.-]+)"', script))

missing = sorted(u for u in used if u not in declared)
for m in missing:
    print(f"  \033[31mFAIL\033[0m mirror-images.sh pushes to '{m}', which ecr_repositories does not declare")

if missing:
    print(f"\n{len(missing)} repository/repositories would not exist at mirror time.")
    sys.exit(1)
print(f"  \033[32mok\033[0m   all {len(used)} mirrored repositories are declared in Terraform")
PY
