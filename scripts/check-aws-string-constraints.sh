#!/usr/bin/env bash
#
# Catch strings that Terraform accepts and the AWS API rejects.
#
# These do not fail `terraform validate`, `terraform plan`, or any module test.
# They fail mid-apply, after real resources exist, with errors that name a regex
# rather than the offending character. One run of this would have caught five
# such failures at once.
#
# Three separate character sets are involved, and they disagree:
#
#   IAM description       [\t\n\r\x20-\x7E\xA1-\xFF]      no em dash (U+2014)
#   EC2 SG description    a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* no apostrophe
#   AWS tag VALUES        letters, numbers, spaces, + - = . _ : / @
#                                                        no parens, no commas
#
# Prose written naturally violates all three.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)/terraform"

python3 - <<'PY'
import re, glob, sys

SG_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            "0123456789. _-:/()#,@[]+=&;{}!$*")
TAG_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
             "0123456789 +-=._:/@")
# Strip ${...} first. Whatever is inside an interpolation is evaluated before
# the API ever sees it, so `azs[count.index]` must not be read as a literal
# bracket. Only the surrounding literal text is checked.
INTERP_RE = re.compile(r"\$\{[^}]*\}")

def literal(v):
    return INTERP_RE.sub("", v)

problems = []

def scan_block(kind, body, path):
    for m in re.finditer(r'^\s*description\s*=\s*"([^"]*)"', body, re.M):
        val = m.group(1)
        if kind == "aws_security_group" or kind.startswith("aws_vpc_security_group"):
            bad = {c for c in literal(val) if c not in SG_OK}
            if bad:
                problems.append((path, kind, "description", "".join(sorted(bad)), val))
        else:
            bad = {c for c in literal(val)
                   if ord(c) > 126 and not (0xA1 <= ord(c) <= 0xFF)}
            if bad:
                problems.append((path, kind, "description", "".join(sorted(bad)), val))

for path in glob.glob("modules/*/*.tf") + glob.glob("envs/*/*.tf"):
    txt = open(path).read()
    for m in re.finditer(r'resource\s+"(aws_[a-z0-9_]+)"\s+"[a-z0-9_]+"\s*\{', txt):
        kind, start = m.group(1), m.end()
        depth, i = 1, start
        while depth and i < len(txt):
            depth += (txt[i] == '{') - (txt[i] == '}')
            i += 1
        scan_block(kind, txt[start:i], path)

# Tag values: any literal string assigned inside a tags/default_tags map.
for path in glob.glob("modules/*/*.tf") + glob.glob("envs/*/*.tf"):
    txt = open(path).read()
    for m in re.finditer(r'\btags\s*=\s*merge\(|^\s*tags\s*=\s*\{|default_tags\s*\{', txt, re.M):
        start = txt.find("{", m.start())
        if start < 0:
            continue
        depth, i = 1, start + 1
        while depth and i < len(txt):
            depth += (txt[i] == '{') - (txt[i] == '}')
            i += 1
        for tm in re.finditer(r'"?[A-Za-z_]+"?\s*=\s*"([^"]*)"', txt[start:i]):
            val = tm.group(1)
            bad = {c for c in literal(val) if c not in TAG_OK}
            if bad:
                problems.append((path, "tag value", "tags", "".join(sorted(bad)), val))

for p in problems:
    print(f"  \033[31mFAIL\033[0m {p[1]} {p[2]} contains [{p[3]}]")
    print(f"       {p[4][:100]}")
    print(f"       {p[0]}")

if problems:
    print(f"\n{len(problems)} string(s) would be rejected by the AWS API.")
    sys.exit(1)
print("  \033[32mok\033[0m   AWS-facing descriptions and tag values are within API character sets")
PY
