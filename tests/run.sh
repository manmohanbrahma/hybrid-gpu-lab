#!/bin/bash
# Checks that need no root and no KVM: shellcheck, and ./lab plan rendered from the example settings
# (network XML well formed, cloud-init valid YAML with the expected users and keys, one virt-install per VM).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if command -v shellcheck >/dev/null; then
  echo "== shellcheck"; shellcheck -x -S warning lab tests/run.sh && echo "   ok" || fail=1
else echo "== shellcheck not installed: skipped"; fi

echo "== plan from lab.conf.example"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForTheTestSuite000000000000000 admin@test\n' > "$tmp/admin.pub"
cp lab.conf.example "$tmp/lab.conf"
sed -i "s|^LAB_ADMIN_KEY=.*|LAB_ADMIN_KEY=$tmp/admin.pub|" "$tmp/lab.conf"
mkdir -p "$tmp/home"; cp lab versions.env "$tmp/home/"; cp "$tmp/lab.conf" "$tmp/home/lab.conf"
if LAB_STATE=$tmp/state "$tmp/home/lab" plan > "$tmp/plan.txt" 2>&1; then echo "   ok"; else cat "$tmp/plan.txt"; fail=1; fi

echo "== network XML"
sed -n 's/^  | //p' "$tmp/plan.txt" | sed -n '/^<network>/,/^<\/network>/p' > "$tmp/net.xml"
python3 - "$tmp/net.xml" <<'PY' && echo "   ok" || fail=1
import sys, xml.etree.ElementTree as ET
n = ET.parse(sys.argv[1]).getroot()
hosts = {h.get("name"): h.get("ip") for h in n.iter("host")}
assert hosts == {"cp1": "192.168.120.11", "cp2": "192.168.120.12", "cp3": "192.168.120.13",
                 "gpu-amd": "192.168.120.21", "gpu-nvidia": "192.168.120.22"}, hosts
assert n.find("forward").get("mode") == "nat"
PY

echo "== cloud-init and virt-install"
python3 - "$tmp/plan.txt" <<'PY' && echo "   ok" || fail=1
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"# cloud-init user-data for (\S+):\n((?:  \| .*\n)+)", text)
assert len(blocks) == 5, [b[0] for b in blocks]
try:
    import yaml
except ImportError:
    yaml = None
for name, block in blocks:
    body = "".join(l[4:] + "\n" for l in block.splitlines())
    assert body.startswith("#cloud-config"), name
    if yaml:
        doc = yaml.safe_load(body)
        assert doc["hostname"] == name
        keys = doc["users"][0]["ssh_authorized_keys"]
        assert any("admin@test" in k for k in keys), (name, keys)   # LAB_ADMIN_KEY_ON=all
        assert doc["users"][0]["lock_passwd"] is True and doc["ssh_pwauth"] is False
installs = re.findall(r"\+ virt-install (.*)", text)
assert len(installs) == 5
gpu = [l for l in installs if "--hostdev" in l]
assert len(gpu) == 2 and all(l.count("--hostdev") == 2 for l in gpu), gpu
assert all("X-PciMmio64Mb" in l for l in gpu)
assert all("OVMF_CODE_4M.fd" in l and "loader_secure=no" in l and "host-passthrough" in l for l in installs)
assert all("on_reboot=restart" in l and "device=cdrom" in l and "--cloud-init" not in l for l in installs)
PY

echo "== admin key on control-plane VMs only"
sed -i 's/^LAB_ADMIN_KEY_ON=.*/LAB_ADMIN_KEY_ON=control/' "$tmp/home/lab.conf"
LAB_STATE=$tmp/state "$tmp/home/lab" plan > "$tmp/plan2.txt" 2>&1
python3 - "$tmp/plan2.txt" <<'PY' && echo "   ok" || fail=1
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"# cloud-init user-data for (\S+):\n((?:  \| .*\n)+)", text)
assert len(blocks) == 5, [b[0] for b in blocks]
for name, block in blocks:
    has = "admin@test" in block
    assert has == name.startswith("cp"), (name, has)
PY

[ $fail = 0 ] && echo "all checks passed" || echo "CHECKS FAILED"
exit $fail
