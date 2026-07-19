#!/usr/bin/env python3
"""CI: download the DiskJockey App Store provisioning profiles from App Store
Connect and install them so xcodebuild can sign manually. Idempotent; no secret
values are printed. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_API_KEY_B64 (base64 .p8).

Requires ALL of the profiles below (one per app/extension bundle id); the export
plist references each explicitly, so a partial set must fail HERE — naming the
missing profile — rather than later during `xcodebuild -exportArchive`. Profiles
are written to ~/Library/MobileDevice/Provisioning Profiles/<UUID>.provisionprofile.
"""
import base64, json, time, os, sys, urllib.request, urllib.error
from cryptography.hazmat.primitives.asymmetric import ec, utils as asymutils
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import load_pem_private_key

# The App Store distribution profiles this build must sign against — every one
# is required (they map 1:1 to the provisioningProfiles in ExportOptions.plist).
REQUIRED = [
    "DiskJockey-app-AppStore",
    "DiskJockey-fileprovider-AppStore",
    "DiskJockey-ntfs-AppStore",
    "DiskJockey-ext4-AppStore",
    "DiskJockey-erofs-AppStore",
    "DiskJockey-squashfs-AppStore",
]

kid = os.environ["ASC_KEY_ID"].strip()
iss = os.environ["ASC_ISSUER_ID"].strip()
p8 = base64.b64decode(os.environ["ASC_API_KEY_B64"].strip())

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
def jwt():
    key = load_pem_private_key(p8, None); now = int(time.time())
    h = b64u(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    pl = b64u(json.dumps({"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    si = h + b"." + pl
    r, s = asymutils.decode_dss_signature(key.sign(si, ec.ECDSA(hashes.SHA256())))
    return (si + b"." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()
def api(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": "Bearer " + jwt()})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

# Fetch ALL profiles, following pagination — a required profile may sit past the
# first page once the account accumulates >200 profiles.
def all_profiles():
    items, path = [], "/v1/profiles?limit=200&fields[profiles]=name,uuid,profileContent,profileState"
    while path:
        page = api(path)
        items.extend(page.get("data", []))
        nxt = (page.get("links") or {}).get("next")
        path = nxt[len("https://api.appstoreconnect.apple.com"):] if nxt else None
    return items

by_name = {}
for p in all_profiles():
    by_name[p["attributes"]["name"]] = p["attributes"]

dest = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
os.makedirs(dest, exist_ok=True)

missing, inactive = [], []
for name in REQUIRED:
    a = by_name.get(name)
    if a is None:
        missing.append(name); continue
    if a.get("profileState") != "ACTIVE":
        inactive.append(f"{name} ({a.get('profileState')})"); continue
    open(os.path.join(dest, a["uuid"] + ".provisionprofile"), "wb").write(base64.b64decode(a["profileContent"]))
    print(f"installed {name}  ({a['uuid']})")

if missing or inactive:
    if missing:   print("ERROR: missing App Store profiles: " + ", ".join(missing), file=sys.stderr)
    if inactive:  print("ERROR: non-ACTIVE App Store profiles: " + ", ".join(inactive), file=sys.stderr)
    sys.exit(1)
print(f"all {len(REQUIRED)} required profile(s) installed into {dest}")
