#!/usr/bin/env python3
"""CI: download the DiskJockey App Store provisioning profiles from App Store
Connect and install them so xcodebuild can sign manually. Idempotent; no secret
values are printed. Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_API_KEY_B64 (base64 .p8).

Profiles are matched by the name prefix used when they were created
(DiskJockey-*-AppStore) and written to
~/Library/MobileDevice/Provisioning Profiles/<UUID>.provisionprofile.
"""
import base64, json, time, os, sys, urllib.request, urllib.error
from cryptography.hazmat.primitives.asymmetric import ec, utils as asymutils
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import load_pem_private_key

kid=os.environ["ASC_KEY_ID"].strip()
iss=os.environ["ASC_ISSUER_ID"].strip()
p8=base64.b64decode(os.environ["ASC_API_KEY_B64"].strip())
PREFIX=os.environ.get("PROFILE_PREFIX","DiskJockey-")

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
def jwt():
    key=load_pem_private_key(p8,None); now=int(time.time())
    h=b64u(json.dumps({"alg":"ES256","kid":kid,"typ":"JWT"}).encode())
    pl=b64u(json.dumps({"iss":iss,"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"}).encode())
    si=h+b"."+pl
    r,s=asymutils.decode_dss_signature(key.sign(si,ec.ECDSA(hashes.SHA256())))
    return (si+b"."+b64u(r.to_bytes(32,"big")+s.to_bytes(32,"big"))).decode()
def api(path):
    req=urllib.request.Request("https://api.appstoreconnect.apple.com"+path,
        headers={"Authorization":"Bearer "+jwt()})
    with urllib.request.urlopen(req,timeout=60) as r: return json.load(r)

dest=os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
os.makedirs(dest,exist_ok=True)

data=api("/v1/profiles?limit=200&fields[profiles]=name,uuid,profileContent,profileState")["data"]
installed=0
for p in data:
    a=p["attributes"]
    if not a["name"].startswith(PREFIX): continue
    if a.get("profileState")!="ACTIVE": continue
    content=base64.b64decode(a["profileContent"])
    path=os.path.join(dest,a["uuid"]+".provisionprofile")
    open(path,"wb").write(content)
    print(f"installed {a['name']}  ({a['uuid']})")
    installed+=1
if installed==0:
    print("ERROR: no matching profiles found",file=sys.stderr); sys.exit(1)
print(f"{installed} profile(s) installed into {dest}")
