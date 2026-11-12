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

echo "== start, stop, restart (fake virsh and ssh)"
fv=$tmp/fakevirsh; mkdir -p "$fv/bin"
cat > "$fv/bin/virsh" <<'EOF'
#!/bin/bash
# a fake virsh: one state file per VM in $FV; every start, shutdown and resume is recorded in $FV/calls
a=(); for x; do [ "$x" = -q ] || a+=("$x"); done; set -- "${a[@]}"
case $1 in
  domstate) [ -f "$FV/$2.state" ] && cat "$FV/$2.state" ;;
  start|resume) echo "$1 $2" >> "$FV/calls"; echo running > "$FV/$2.state" ;;
  shutdown|destroy) echo "$1 $2" >> "$FV/calls"; echo "shut off" > "$FV/$2.state" ;;
  list) for f in "$FV"/*.state; do [ "$(cat "$f")" = running ] && basename "$f" .state; done; true ;;
  dumpxml) cat "$FV/$2.xml" 2>/dev/null; true ;;
  net-info) echo "Active:         yes" ;;
  *) echo "fake virsh: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fv/bin/virsh"
lab_run() {   # FAKE_K8S command...: run lab functions against the fake; output in $tmp/out
  local k8s=$1; shift
  ( export PATH="$fv/bin:$PATH" FV=$fv FAKE_K8S=$k8s
    # shellcheck source=../lab
    . ./lab
    LAB_HOME=$tmp/home; STATE=$tmp/state; LOG=$tmp/lab.log; LAB_SHUTDOWN_WAIT=2; LAB_K8S_WAIT=2
    load_config
    vssh() {   # a VM answers SSH once running; Kubernetes on the control planes when FAKE_K8S=1
      [ "$(dom_state "hl-$1")" = running ] || return 255
      case $2 in
        *"test -r"*) [ "$FAKE_K8S" = 1 ] ;;
        *"get nodes"*) echo "k8s-get-nodes" >> "$FV/calls"
          for n in cp1 cp2 cp3 gpu-amd gpu-nvidia; do
            if [ "$(dom_state "hl-$n")" = running ]; then echo "$n Ready x 9d v1"; else echo "$n NotReady x 9d v1"; fi; done ;;
        *) true ;;
      esac; }
    "$@" ) > "$tmp/out" 2>&1
}
fv_reset() { rm -f "$fv"/*.state "$fv"/*.xml "$fv/calls"; touch "$fv/calls"
  for n in cp1 cp2 cp3 gpu-amd gpu-nvidia; do echo "shut off" > "$fv/hl-$n.state"; done; }
line_of() { grep -nxF "$1" "$fv/calls" | head -1 | cut -d: -f1; }
t_fail=0; tcheck() { if eval "$2"; then :; else echo "   FAIL: $1"; cat "$tmp/out"; echo "   calls:"; sed 's/^/     /' "$fv/calls"; t_fail=1; fi; }

fv_reset; lab_run 1 lab_start
tcheck "start: all five started" '[ "$(grep -c "^start " "$fv/calls")" = 5 ]'
tcheck "start: control planes before the API check, workers after it" \
  '[ "$(line_of "start hl-cp3")" -lt "$(line_of k8s-get-nodes)" ] && [ "$(line_of k8s-get-nodes)" -lt "$(line_of "start hl-gpu-amd")" ]'
tcheck "start: all nodes Ready reported" 'grep -q "Kubernetes: 5 of 5 nodes Ready$" "$tmp/out" && grep -q "kubernetes: 5 of 5 nodes Ready" "$tmp/out"'

lab_run 1 lab_stop
tcheck "stop: workers shut down before the control planes" \
  '[ "$(line_of "shutdown hl-gpu-nvidia")" -lt "$(line_of "shutdown hl-cp1")" ] && [ "$(line_of "shutdown hl-gpu-amd")" -lt "$(line_of "shutdown hl-cp1")" ]'
tcheck "stop: all shut off" '[ "$(grep -l "shut off" "$fv"/hl-*.state | wc -l)" = 5 ]'

fv_reset; lab_run 0 lab_start cp1 gpu-amd
tcheck "start cp1 gpu-amd: only those two, no Kubernetes" \
  '[ "$(paste -sd, "$fv/calls")" = "start hl-cp1,start hl-gpu-amd" ]'

fv_reset; lab_run 1 lab_start cp1 cp2 cp3 gpu-amd
tcheck "start without gpu-nvidia: its NotReady node is not waited for" \
  'grep -q "Kubernetes: 4 of 5 nodes Ready (off: gpu-nvidia)" "$tmp/out" && ! grep -q "not Ready after" "$tmp/out"'

fv_reset; echo running > "$fv/hl-other.state"
printf '%s\n' "<domain>" "  <hostdev mode='subsystem' type='pci' managed='no'>" "    <source>" \
  "      <address domain='0x0000' bus='0x82' slot='0x00' function='0x0'/>" "    </source>" \
  "    <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>" "  </hostdev>" "</domain>" > "$fv/hl-other.xml"
lab_run 0 lab_start gpu-nvidia && t_fail=1
tcheck "start: refused while another VM holds the GPU" 'grep -q "which VM hl-other is using" "$tmp/out" && ! grep -q "start hl-gpu-nvidia" "$fv/calls"'
lab_run 0 lab_start gpu-amd
tcheck "start: a GPU held elsewhere does not block the other worker" 'grep -qx "start hl-gpu-amd" "$fv/calls"'

lab_run 0 check_names cp1 nope && t_fail=1
tcheck "unknown VM name refused" 'grep -q "no VM named nope" "$tmp/out"'

echo "in shutdown" > "$fv/hl-cp2.state"; (sleep 0.5; echo "shut off" > "$fv/hl-cp2.state") &
lab_run 0 lab_start cp2; wait
tcheck "start: waits for a VM that is still shutting down" 'grep -qx "start hl-cp2" "$fv/calls"'
[ $t_fail = 0 ] && echo "   ok" || fail=1

[ $fail = 0 ] && echo "all checks passed" || echo "CHECKS FAILED"
exit $fail
