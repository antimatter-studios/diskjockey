#!/usr/bin/env bash
#
# xfs-mutations.sh — the XFS FSKit mutation oracle runs in CI, and its Linux
# half runs in fs-linux-test-harness's VM, never on the runner (#355).
#
# The oracle needs a KVM runner, a macOS runner and a 400 MiB image, so it
# runs in the XFS mutations workflow, not here. What this job CAN prove, with
# nothing installed:
#
#   1. the workflow hands the image from `image` to `native` to `verify`, runs
#      on every pull request that changes DiskJockeyXFS/ or what the oracle is
#      built from, bounds every job and every oracle step, and .github-guard
#      declares each job advisory;
#   2. both Linux jobs boot the harness VM on an x86_64 runner (GitHub's arm64
#      runners have no KVM), from the tag SIBLING_PINS.txt pins, make the
#      runner's own xfsprogs unusable first, and reach the guest script only
#      through scripts/xfs-mutations-vm.sh: no step installs xfsprogs on a
#      runner or runs the guest script there;
#   3. the guest script points no image tool at the shared directory, and the
#      harness's setup script installs the tools it calls;
#   4. the native half compiles every XFS source the volume needs: all of
#      DiskJockeyXFS/*.swift but XfsFileSystem.swift, whose loadResource the
#      oracle repeats call for call.
#
# Every check is also run against a broken copy, and must refuse it: a gate
# that cannot fail is indistinguishable from no gate.
#
#   bash scripts/tests/xfs-mutations.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/xfs-mutations.yml"
GUEST="$REPO/scripts/oracles/xfs-mutations-linux.sh"
NATIVE="$REPO/scripts/test-xfs-mutations.sh"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

command -v ruby >/dev/null 2>&1 || { echo "xfs-mutations: ruby is required to parse the workflow" >&2; exit 1; }
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# workflow_problems FILE — one line per way FILE breaks 1 and 2; none when sound.
workflow_problems() {
    ruby -ryaml -e '
        w = YAML.safe_load(File.read(ARGV[0]), aliases: true) || {}
        p = ->(m) { puts m }
        on = w[true] || w["on"] || {}
        pr = (on["pull_request"] || {})["paths"] || []
        push = ((on["push"] || {})["paths"] || [])
        %w[DiskJockeyXFS/** rust-bundles/dj-xfs-bundle/** scripts/test-xfs-mutations.sh
           scripts/xfs-mutations-vm.sh scripts/oracles/xfs-mutations.swift
           scripts/oracles/xfs-mutations-linux.sh scripts/oracles/vm-setup.sh
           fs-linux-test-harness.toml SIBLING_PINS.txt].each do |path|
          p.("pull requests changing #{path} do not run it") unless pr.include?(path)
        end
        p.("main runs it on other paths than pull requests do") unless push.sort == pr.sort
        jobs = w["jobs"] || {}
        names = { "image" => "XFS mutations (Linux image)", "native" => "XFS mutations (macOS FSKit volume)",
                  "verify" => "XFS mutations (Linux verify)" }
        names.each do |id, name|
          job = jobs[id]
          next p.("there is no #{id} job") unless job
          p.("job #{id} is named #{job["name"].inspect}, not #{name.inspect}") unless job["name"] == name
          p.("job #{id} has no timeout-minutes") unless job["timeout-minutes"].is_a?(Integer)
        end
        p.("native does not need image") unless Array(jobs.dig("native", "needs")).include?("image")
        p.("verify does not need native") unless Array(jobs.dig("verify", "needs")).include?("native")
        jobs.each do |id, job|
          (job["steps"] || []).each do |s|
            run = s["run"].to_s
            p.("#{id} installs xfsprogs on the runner") if run =~ /apt(-get)?\s+install[^\n]*xfsprogs/
            p.("#{id} runs the guest script on the runner") if run.include?("xfs-mutations-linux.sh")
          end
        end
        { "image" => "create", "verify" => "verify" }.each do |id, action|
          job = jobs[id] or next
          steps = job["steps"] || []
          runner = job["runs-on"].to_s
          p.("#{id} runs on #{runner}, not an x86_64 ubuntu runner with KVM") unless runner.start_with?("ubuntu-") && !runner.include?("arm")
          find = ->(re) { steps.index { |s| s["run"].to_s =~ re } }
          clone = find.(/SIBLING_PINS\.txt[\s\S]*fs-linux-test-harness/)
          setup = find.(/fs-linux-test-harness\/scripts\/ci-setup-linux\.sh/)
          poison = find.(/the oracle tools belong in the VM/)
          oracle = find.(/scripts\/xfs-mutations-vm\.sh #{action} /)
          p.("#{id} does not check the harness out at the pinned tag") unless clone
          p.("#{id} does not set the runner up to boot the VM") unless setup
          p.("#{id} never makes the runner xfsprogs unusable") unless poison
          next p.("#{id} does not run scripts/xfs-mutations-vm.sh #{action}") unless oracle
          p.("#{id} runs the oracle before the runner xfsprogs is unusable") if poison && poison > oracle
          p.("#{id} runs the oracle with no step timeout") unless steps[oracle]["timeout-minutes"]
        end
        native = jobs["native"] || {}
        p.("native does not run on macOS") unless native["runs-on"].to_s.start_with?("macos")
        step = (native["steps"] || []).find { |s| s["run"].to_s.include?("scripts/test-xfs-mutations.sh") }
        if step.nil? then p.("native does not run scripts/test-xfs-mutations.sh")
        elsif !step["timeout-minutes"] then p.("native runs the oracle with no step timeout") end
    ' "$1"
}

# guest_problems FILE — an image tool pointed at the share, or no scratch disk.
guest_problems() {
    grep -nE '^[^#]*\b(xfs_repair|xfs_db|xfs_logprint|mkfs\.xfs|mount)\b[^#]*("\$image"|\$image\b|/share)' "$1" \
        | sed 's/^/an image tool works on the share: /'
    grep -qE 'mktemp -d /var/tmp/' "$1" || echo 'no scratch directory on the guest disk'
}

# sources_problems FILE — the XFS sources the native half does not compile.
sources_problems() {
    local f
    for f in "$REPO"/DiskJockeyXFS/*.swift; do
        f="DiskJockeyXFS/${f##*/}"
        [ "$f" = DiskJockeyXFS/XfsFileSystem.swift ] && continue
        grep -qF "$f" "$1" || echo "$1 does not compile $f"
    done
}

# expect_clean LABEL OUTPUT / expect_refused LABEL OUTPUT
expect_clean() {
    if [ -z "$2" ]; then ok "$1"; else fail "$1:"; printf '%s\n' "$2" | sed 's/^/      /'; fi
}
expect_refused() {
    if [ -n "$2" ]; then ok "$1"; else fail "$1: nothing refused it"; fi
}

# ------------------------------------------------------- 1, 2: the workflow
expect_clean "the workflow runs image, native and verify, the Linux two in the harness VM" "$(workflow_problems "$WORKFLOW")"
missing=""
for id in image native verify; do
    name="$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0]), aliases: true)["jobs"][ARGV[1]]["name"].to_s' "$WORKFLOW" "$id" 2>/dev/null)"
    git config -f "$REPO/.github-guard" --get-all checks.advisory | grep -qxF "$name" || missing="$missing [$name]"
    git config -f "$REPO/.github-guard" --get-all checks.required | grep -qxF "$name" && missing="$missing [$name is required]"
done
expect_clean ".github-guard declares all three jobs advisory, none required" "$missing"
pin="$(awk '$1=="fs-linux-test-harness"{print $2}' "$REPO/SIBLING_PINS.txt")"
[[ "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "SIBLING_PINS.txt pins fs-linux-test-harness at the tag $pin" \
    || fail "SIBLING_PINS.txt pins fs-linux-test-harness at '${pin:-nothing}', not a vX.Y.Z tag"

mutate() { # mutate NAME RUBY — the workflow, changed by RUBY acting on `w`
    ruby -ryaml -e 'w = YAML.safe_load(File.read(ARGV[0]), aliases: true); eval(ARGV[2]); File.write(ARGV[1], w.to_yaml)' \
        "$WORKFLOW" "$sandbox/$1.yml" "$2"
    workflow_problems "$sandbox/$1.yml"
}
expect_refused "a verify job that runs the guest script on the runner is refused" \
    "$(mutate direct 's = w["jobs"]["verify"]["steps"].find { |x| x["run"].to_s.include?("xfs-mutations-vm.sh") }; s["run"] = "sudo bash scripts/oracles/xfs-mutations-linux.sh verify tmp/xfs-mutations"')"
expect_refused "an image job on an arm64 runner, which has no KVM, is refused" \
    "$(mutate arm 'w["jobs"]["image"]["runs-on"] = "ubuntu-24.04-arm"')"
expect_refused "a verify job that leaves the runner xfsprogs usable is refused" \
    "$(mutate poison 'w["jobs"]["verify"]["steps"].reject! { |x| x["run"].to_s.include?("belong in the VM") }')"
expect_refused "a workflow that pull requests changing DiskJockeyXFS/ do not run is refused" \
    "$(mutate paths '(w[true] || w["on"])["pull_request"]["paths"].delete("DiskJockeyXFS/**")')"

# ------------------------------------------------- 3: the guest and its tools
expect_clean "the guest script works on its own disk, never on the share" "$(guest_problems "$GUEST")"
sed 's|xfs_repair -n "\$img"|xfs_repair -n "$image"|' "$GUEST" > "$sandbox/guest.sh"
expect_refused "a guest script that runs xfs_repair on the share is refused" "$(guest_problems "$sandbox/guest.sh")"
setup="$(sed -n 's/^script = "\(.*\)"$/\1/p' "$REPO/fs-linux-test-harness.toml")"
if [ -n "$setup" ] && [ -f "$REPO/$setup" ]; then
    absent=""
    for pkg in xfsprogs attr acl; do
        grep -qE "apt-get install[^#]*\b$pkg\b" "$REPO/$setup" || absent="$absent $pkg"
    done
    expect_clean "the harness setup script, $setup, installs xfsprogs, attr and acl in the guest" "$absent"
else
    fail "fs-linux-test-harness.toml names no setup script that exists (got '${setup:-nothing}')"
fi

# --------------------------------------------- 4: the native half's sources
expect_clean "the native half compiles every XFS source but XfsFileSystem.swift" "$(sources_problems "$NATIVE")"
sed 's| DiskJockeyXFS/XfsCheck.swift||' "$NATIVE" > "$sandbox/native.sh"
expect_refused "a native half that leaves XfsCheck.swift out is refused" "$(sources_problems "$sandbox/native.sh")"

echo
if [ "$fails" -eq 0 ]; then
    echo 'xfs-mutations: all checks passed'
    exit 0
fi
echo "xfs-mutations: $fails check(s) failed" >&2
exit 1
