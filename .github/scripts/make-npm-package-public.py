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
    "X-GitHub-Api-Version": "2022-11-28",
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


packages = []
for visibility in ("private", "public"):
    status, listed = request(f"https://api.github.com/orgs/nightpay/packages?package_type=npm&visibility={visibility}")
    print(f"{visibility}_list_http", status)
    if isinstance(listed, list):
        packages.extend(listed)
        print(f"{visibility}_list_count", len(listed))
    else:
        print(f"{visibility}_list_error", listed.get("message"))
repo_status, repo_packages = request("https://api.github.com/repos/nightpay/nightpay/packages?package_type=npm")
print("repo_list_http", repo_status)
if isinstance(repo_packages, list):
    packages.extend(repo_packages)
else:
    print("repo_list_error", repo_packages.get("message"))

names = []
for item in packages:
    if item.get("name"):
        names.append(item["name"])
names.extend(["nightpay", "@nightpay/nightpay"])
seen = set()
print("package_count", len(packages))
for name in names:
    if name in seen:
        continue
    seen.add(name)
    encoded = urllib.parse.quote(name, safe="")
    get_code, current = request(f"https://api.github.com/orgs/nightpay/packages/npm/{encoded}")
    print(
        "get_http", get_code,
        "query", name,
        "name", current.get("name"),
        "visibility", current.get("visibility"),
        "message", current.get("message"),
    )
    if get_code != 200 or current.get("visibility") == "public":
        continue
    code, updated = request(
        f"https://api.github.com/orgs/nightpay/packages/npm/{encoded}",
        method="PATCH",
        body={"visibility": "public"},
    )
    print("update_http", code, "name", updated.get("name"), "visibility", updated.get("visibility"), "message", updated.get("message"))
