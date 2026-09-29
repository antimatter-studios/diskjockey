#!/usr/bin/env bash
#
# release-is-attested.sh — the release build is attested before it is uploaded.
#
# `release.yml` signs a build-provenance attestation over the installer package
# it exports, so the owner can prove that what reached the App Store was built
# by this repository's release workflow from a commit here, not on someone's
# machine:
#
#   gh attestation verify DiskJockey.pkg --repo antimatter-studios/diskjockey \
#     --signer-workflow antimatter-studios/diskjockey/.github/workflows/release.yml
#
# Nothing else notices if that step goes. The workflow is dispatch-only and
# signs with the owner's certificates, so nothing runs it on a pull request, and
# a build without an attestation uploads exactly as green as one with it. The
# loss would surface the first time someone tried to verify a package, long
# after it shipped. This makes it loud on the pull request that causes it.
#
# Asserted against the PARSED workflow, so a comment naming the action or a step
# named "attest" cannot stand in for the step. The checker is then run against
# broken copies of the workflow: a guard that cannot fail is no guard.
#
#   bash scripts/tests/release-is-attested.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE="$REPO/.github/workflows/release.yml"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v ruby >/dev/null 2>&1 || { echo "release-is-attested: ruby is required to parse the workflow" >&2; exit 1; }

# attestation_gaps <workflow> — one line per gap; empty output means none.
attestation_gaps() {
    ruby -ryaml -e '
        attest = "actions/attest-build-provenance@"
        grants = %w[id-token attestations]
        d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        writes = lambda do |perms|
            next %w[id-token attestations contents] if perms == "write-all"
            next [] unless perms.is_a?(Hash)
            perms.select { |_, v| v == "write" }.keys
        end
        gaps = []
        writes.call(d["permissions"]).each { |g| gaps << "the workflow-level permissions grant #{g}: write" }
        attesting = 0
        (d["jobs"] || {}).each do |name, job|
            steps = job["steps"] || []
            granted = writes.call(job["permissions"])
            at = steps.index { |s| s["uses"].to_s.start_with?(attest) }
            if at.nil?
                granted.each { |g| gaps << "job #{name} attests nothing but holds #{g}: write" }
                next
            end
            attesting += 1
            pin = steps[at]["uses"].to_s.sub(attest, "").split.first.to_s
            gaps << "job #{name} pins #{attest}#{pin}, not a full commit SHA" unless pin.match?(/\A[0-9a-f]{40}\z/)
            subject = ((steps[at]["with"] || {})["subject-path"]).to_s
            gaps << "job #{name} attests #{subject.inspect}, not the exported .pkg" unless subject.include?("EXPORT_PATH") && subject.end_with?(".pkg")
            named = lambda { |n| steps.index { |s| s["name"] == n } }
            export, upload = named.call("Export for App Store"), named.call("Upload to the Mac App Store")
            gaps << "job #{name} attests before the package is exported" unless export && export < at
            gaps << "job #{name} uploads before the package is attested" unless upload.nil? || at < upload
            grants.each { |g| gaps << "job #{name} attests without #{g}: write" unless granted.include?(g) }
            gaps << "job #{name} holds contents: write, and publishes nothing to the repository" if granted.include?("contents")
        end
        gaps << "no job uses #{attest}<sha>" if attesting.zero?
        puts gaps
    ' "$1" 2>&1
}

gaps="$(attestation_gaps "$RELEASE")"
if [ -z "$gaps" ]; then
    ok 'release.yml attests the exported .pkg before uploading it, from the one privileged job'
else
    fail "release.yml attestation: $gaps"
fi

# ------------------------------------------------ the checker can fail
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# broken <label> <expected gap substring> <ruby that edits the parsed workflow `d`>
broken() {
    local label="$1" want="$2" edit="$3" copy="$sandbox/release.yml" got
    ruby -ryaml -e '
        d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        eval(ARGV[1])
        File.write(ARGV[2], YAML.dump(d))
    ' "$RELEASE" "$edit" "$copy" 2>/dev/null || { fail "$label: could not build the broken copy"; return; }
    got="$(attestation_gaps "$copy")"
    case "$got" in
        *"$want"*) ok "rejects: $label" ;;
        *) fail "$label: wanted a gap naming [$want], got [$got]" ;;
    esac
}

steps='d["jobs"]["archive"]["steps"]'
at="$steps.index { |s| s[\"uses\"].to_s.start_with?(\"actions/attest-build-provenance@\") }"
broken 'the attest step removed' 'no job uses' \
    "$steps.delete_at($at)"
broken 'the action pinned to a tag' 'not a full commit SHA' \
    "$steps[$at][\"uses\"] = \"actions/attest-build-provenance@v4\""
broken 'id-token dropped' 'without id-token' \
    'd["jobs"]["archive"]["permissions"].delete("id-token")'
broken 'attestations dropped' 'without attestations' \
    'd["jobs"]["archive"]["permissions"].delete("attestations")'
broken 'contents raised to write' 'holds contents: write' \
    'd["jobs"]["archive"]["permissions"]["contents"] = "write"'
broken 'a grant hoisted to the workflow' 'workflow-level permissions grant id-token' \
    'd["permissions"] = { "id-token" => "write" }'
broken 'attesting something other than the package' 'not the exported .pkg' \
    "$steps[$at][\"with\"][\"subject-path\"] = \"README.md\""
broken 'the upload moved ahead of the attestation' 'uploads before the package is attested' \
    "u = $steps.index { |s| s[\"name\"] == \"Upload to the Mac App Store\" }; $steps.insert($at, $steps.delete_at(u))"

if [ "$fails" -eq 0 ]; then
    echo "release-is-attested: all checks passed"
else
    echo "release-is-attested: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
