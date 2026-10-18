"""Builds THIRD_PARTY_NOTICES.md and the in-app copy (Sources/BunnyGrid/Resources/Licenses/licenses.json) from the
real LICENSE and NOTICE files of every package in Package.resolved (read from .build/checkouts), plus the bundled
artwork and the references. Run after changing dependencies: python3 -I scripts/gen-notices.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUTS = os.path.join(ROOT, ".build", "checkouts")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip()


def find(directory, pattern):
    for name in sorted(os.listdir(directory)):
        if re.match(pattern, name, re.I) and os.path.isfile(os.path.join(directory, name)):
            return os.path.join(directory, name)
    return None


def license_name(text):
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache License 2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT License"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD License"
    return "See license text"


# Display names, and the part of BunnyGrid each package serves.
PACKAGES = {
    "postgres-nio": ("PostgresNIO", "PostgreSQL driver"),
    "mysql-nio": ("MySQLNIO", "MySQL and MariaDB driver"),
    "citadel": ("Citadel", "SSH tunnels"),
    "swift-nio-ssh": ("SwiftNIO SSH (Citadel's fork)", "SSH protocol under Citadel"),
    "swift-nio": ("SwiftNIO", "networking for every server driver"),
    "swift-nio-ssl": ("SwiftNIO SSL", "TLS connections (includes BoringSSL)"),
    "swift-nio-transport-services": ("SwiftNIO Transport Services", "dependency of the drivers"),
    "sparkle": ("Sparkle", "app updates"),
    "bigint": ("BigInt", "dependency of Citadel"),
    "swift-crypto": ("Swift Crypto", "cryptography (includes BoringSSL)"),
    "swift-asn1": ("Swift ASN.1", "dependency of Swift Crypto"),
    "swift-algorithms": ("Swift Algorithms", "dependency of the drivers"),
    "swift-async-algorithms": ("Swift Async Algorithms", "dependency of the drivers"),
    "swift-atomics": ("Swift Atomics", "dependency of SwiftNIO"),
    "swift-collections": ("Swift Collections", "dependency of SwiftNIO"),
    "swift-log": ("Swift Log", "dependency of the drivers"),
    "swift-metrics": ("Swift Metrics", "dependency of the drivers"),
    "swift-numerics": ("Swift Numerics", "dependency of Swift Algorithms"),
    "swift-service-lifecycle": ("Swift Service Lifecycle", "dependency of PostgresNIO"),
    "swift-system": ("Swift System", "dependency of SwiftNIO"),
}

BUNNYGRID = {
    "id": "bunnygrid",
    "name": "BunnyGrid",
    "license": "GNU Affero General Public License v3.0",
    "usage": "",
    "url": "https://github.com/matthfaria96/BunnyGrid",
    "text": (
        "Copyright (C) 2026 Matheus Faria\n"
        "Source code: https://github.com/matthfaria96/BunnyGrid\n\n"
        "BunnyGrid is free software: you can redistribute it and/or modify it under the terms of the GNU Affero "
        "General Public License as published by the Free Software Foundation, either version 3 of the License, or "
        "(at your option) any later version. It is distributed WITHOUT ANY WARRANTY; without even the implied "
        "warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n\n"
        "Full license text: https://www.gnu.org/licenses/agpl-3.0.html"
    ),
}

CC0 = (
    "Creative Commons Zero v1.0 Universal (CC0-1.0): the authors dedicated the work to the public domain.\n"
    "https://creativecommons.org/publicdomain/zero/1.0/"
)

ARTWORK = [
    {
        "id": "simple-icons",
        "name": "Simple Icons 16.33.0",
        "license": "CC0 1.0",
        "usage": "brand logos in New Connection and for AI providers",
        "url": "https://github.com/simple-icons/simple-icons",
        "text": CC0 + "\n\nLogos and brand names are trademarks of their owners; they only identify the product and imply no "
        "endorsement. Per-logo sources: Resources/Icons/brands/SOURCES.md.",
    },
    {
        "id": "ivorysql",
        "name": "IvorySQL logo",
        "license": "CC0 1.0",
        "usage": "New Connection",
        "url": "https://github.com/IvorySQL/Ivory-www",
        "text": CC0,
    },
    {
        "id": "oceanbase",
        "name": "OceanBase logo",
        "license": "Apache License 2.0",
        "usage": "New Connection",
        "url": "https://github.com/oceanbase/oceanbase",
        "text": "From images/logo.svg in the OceanBase repository, licensed under the Apache License 2.0.\n"
        "https://www.apache.org/licenses/LICENSE-2.0",
    },
    {
        "id": "kingbase",
        "name": "Kingbase logo",
        "license": "Owner's public logo pack",
        "usage": "New Connection",
        "url": "https://www.kingbase.com.cn/about/about.html",
        "text": "Published for download by CETC Kingbase with no usage terms attached. Used only to identify the product.",
    },
]

SYSTEM = [
    {
        "id": "sqlite",
        "name": "SQLite",
        "license": "Public domain",
        "usage": "SQLite databases (macOS's own libsqlite3, not bundled)",
        "url": "https://www.sqlite.org/copyright.html",
        "text": "SQLite is in the public domain. https://www.sqlite.org/copyright.html",
    },
]

REFERENCES = [
    ("Beekeeper Studio", "https://github.com/beekeeper-studio/beekeeper-studio", "GPL-3.0",
     "architecture reference (driver contract, connection → tree → tabs); no code copied"),
    ("Navicat Premium", "https://www.navicat.com", "proprietary",
     "layout and feature map from public bundle metadata; no artwork or code copied"),
    ("SF Symbols and the system fonts", "https://developer.apple.com/sf-symbols/", "Apple",
     "icons and text come from macOS itself; no fonts are bundled"),
]


def packages():
    pins = json.load(open(os.path.join(ROOT, "Package.resolved")))["pins"]
    entries = []
    for pin in sorted(pins, key=lambda p: (p["identity"] not in ("postgres-nio", "mysql-nio", "citadel", "sparkle"), p["identity"])):
        identity = pin["identity"]
        directory = next((os.path.join(CHECKOUTS, d) for d in os.listdir(CHECKOUTS) if d.lower() == identity), None)
        if not directory:
            sys.exit(f"missing checkout for {identity}: run swift build first")
        license_file = find(directory, r"^(LICEN[CS]E|COPYING)")
        if not license_file:
            sys.exit(f"no license file in {directory}")
        text = read(license_file)
        notice = find(directory, r"^NOTICE")
        if notice:
            text += "\n\n---- NOTICE ----\n\n" + read(notice)
        name, usage = PACKAGES.get(identity, (identity, "dependency"))
        version = pin["state"].get("version") or pin["state"].get("revision", "")[:8]
        entries.append({
            "id": identity,
            "name": f"{name} {version}",
            "license": license_name(read(license_file)),
            "usage": usage,
            "url": pin["location"].removesuffix(".git"),
            "text": text,
        })
    return entries


def main():
    code = packages()
    entries = [BUNNYGRID] + code + SYSTEM + ARTWORK
    out = os.path.join(ROOT, "Sources", "BunnyGrid", "Resources", "Licenses")
    os.makedirs(out, exist_ok=True)
    payload = {"entries": entries, "references": [dict(zip(("name", "url", "license", "usage"), r)) for r in REFERENCES]}
    with open(os.path.join(out, "licenses.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
        f.write("\n")

    lines = [
        "# Third-Party Notices",
        "",
        "BunnyGrid is Copyright (C) 2026 Matheus Faria and is licensed under the GNU Affero General Public License",
        "v3.0 (see `LICENSE`). It is built on the open-source projects listed below. Each project's notice is kept as",
        "its license requires; MIT, BSD and Apache-2.0 code is compatible with, and distributed under, the AGPL as part",
        "of BunnyGrid. The same notices are in the app: Settings › About › Open-source licenses.",
        "",
        "This file is generated by `scripts/gen-notices.py` from the packages' own LICENSE and NOTICE files.",
        "",
        "## Open-source code",
        "",
    ]
    for entry in code + SYSTEM:
        lines += [f"### {entry['name']}", "", f"- Source: {entry['url']}", f"- License: {entry['license']}",
                  f"- Used in: {entry['usage']}", "", "```", entry["text"], "```", ""]
    lines += ["## Artwork", ""]
    for entry in ARTWORK:
        lines += [f"### {entry['name']}", "", f"- Source: {entry['url']}", f"- License: {entry['license']}",
                  f"- Used in: {entry['usage']}", "", entry["text"], ""]
    lines += ["## References (no code or artwork copied)", ""]
    for name, url, license, usage in REFERENCES:
        lines.append(f"- [{name}]({url}) ({license}): {usage}.")
    with open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(entries)} entries, {len(REFERENCES)} references")


if __name__ == "__main__":
    main()
