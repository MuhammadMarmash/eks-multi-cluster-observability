#!/usr/bin/env bash
#
# Assert that the ECR repositories envs/prod declares and the ones
# scripts/mirror-images.sh pushes to are the SAME SET, in both directions.
#
# These two lists live in different files and are edited at different times.
# Pushed-but-undeclared fails loudly, though late: `make mirror` gets halfway
# through pushing gigabytes and hits "The repository with name '...' does not
# exist", after the infrastructure apply has already succeeded.
#
# Declared-but-unpushed fails silently, which is worse. The repository is
# created on every apply and stays empty forever, and the only way to notice is
# to compare two files by eye. Five such repositories survived a rewrite of the
# workload application before this check existed.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

python3 - <<'PY'
import re, sys

tf = open("terraform/envs/prod/variables.tf").read()
block = re.search(r'variable\s+"ecr_repositories".*?\n\}', tf, re.S)
declared = set(re.findall(r'^\s+"([a-z0-9/_.-]+)"\s+=', block.group(0), re.M)) if block else set()

script = open("scripts/mirror-images.sh").read()
# The character class must admit ${...}: a repository name may be built in a
# shell loop, e.g. "mirror/jetstack/cert-manager-${component}".
used = set(re.findall(r'mirror_image\s+"[^"]+"\s*\\?\s*\n?\s*"([A-Za-z0-9/_.${}-]+)"', script))
used |= set(re.findall(r'mirror_chart\s+"[^"]+"\s+"[^"]+"\s+"([A-Za-z0-9/_.${}-]+)"', script))

# A repository name in the script may contain a shell interpolation, e.g.
# "mirror/jetstack/cert-manager-${component}" inside a for loop. Treat those as
# patterns rather than reporting every expansion as missing.
def to_pattern(name):
    if "${" not in name:
        return re.compile("^" + re.escape(name) + "$")
    prefix = name.split("${", 1)[0]
    return re.compile("^" + re.escape(prefix) + ".*$")

patterns = [to_pattern(u) for u in used]
literals = {u for u in used if "${" not in u}

problems = []
for u in sorted(literals - declared):
    problems.append(f"mirror-images.sh pushes to '{u}', which ecr_repositories does not declare")
for d in sorted(declared):
    if not any(p.match(d) for p in patterns):
        problems.append(f"ecr_repositories declares '{d}', which nothing ever pushes to")

for m in problems:
    print(f"  \033[31mFAIL\033[0m {m}")

if problems:
    print(f"\n{len(problems)} repository/repositories are out of sync.")
    sys.exit(1)
print(f"  \033[32mok\033[0m   {len(declared)} declared repositories match what the mirror script pushes")
PY
