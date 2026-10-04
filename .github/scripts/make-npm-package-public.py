import json
import os
import urllib.error
import urllib.parse
import urllib.request

token = os.environ["NODE_AUTH_TOKEN"]
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json",
}


def request(url, method="GET", body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read().decode()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw[:200]}
        return exc.code, payload


status, packages = request("https://api.github.com/orgs/nightpay/packages?package_type=npm&visibility=private")
print("private_list_http", status)
if not isinstance(packages, list):
    print("private_list_error", packages.get("message"))
    packages = []
repo_status, repo_packages = request("https://api.github.com/repos/nightpay/nightpay/packages?package_type=npm")
print("repo_list_http", repo_status)
if isinstance(repo_packages, list):
    packages.extend(repo_packages)
else:
    print("repo_list_error", repo_packages.get("message"))
seen = set()
print("package_count", len(packages))
for item in packages:
    name = item.get("name")
    if name in seen:
        continue
    seen.add(name)
    print("found", name, item.get("visibility"))
    encoded = urllib.parse.quote(name or "", safe="")
    code, updated = request(
        f"https://api.github.com/orgs/nightpay/packages/npm/{encoded}",
        method="PATCH",
        body={"visibility": "public"},
    )
    print("update_http", code, "name", updated.get("name"), "visibility", updated.get("visibility"), "message", updated.get("message"))
