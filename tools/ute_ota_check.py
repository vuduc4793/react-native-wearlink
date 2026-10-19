"""Hỏi server UTE có firmware mới không, theo cách app GloryFitPro (JSON mã hoá RSA từng 32 ký tự, multipart "content").

Dùng: python3 -I tools/ute_ota_check.py <appkey> <btname> <versionname> <mac> <url API>
Xem sdks/gloryfit/docs/04-firmware.md §4.
"""
import base64, json, sys, urllib.request, uuid
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding
PUB = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC57TJWQJc+vSp+Lq5ctZIhT3tZAWJMsgHLexnPUkix6ci52M9lIKglwthipBlExFs8TN/1eY6Y56oJce+AMlIakVEg+UZJ1kHFRDwzJdpG/Lb8hi61fknkhROu6sB3xcG9jUWpWTLRl3KTAd4AGiEgPdDS3bdA+oFr6lygvj9SlQIDAQAB"
key = load_der_public_key(base64.b64decode(PUB))
appkey, btname, version, mac, url = sys.argv[1:6]
req = {"appkey": appkey, "btname": btname, "language": "en", "mac": mac, "versionname": version}
s = json.dumps(req, separators=(",", ":"))
enc = "".join(base64.b64encode(key.encrypt(s[i:i+32].encode(), padding.PKCS1v15())).decode() for i in range(0, len(s), 32))
b = uuid.uuid4().hex
body = f'--{b}\r\nContent-Disposition: form-data; name="content"\r\nContent-Length: {len(enc)}\r\n\r\n{enc}\r\n--{b}--\r\n'.encode()
r = urllib.request.Request(url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={b}"})
print(s); print(urllib.request.urlopen(r, timeout=20).read().decode()[:1500])
