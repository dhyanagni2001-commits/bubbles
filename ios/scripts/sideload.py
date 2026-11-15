#!/usr/bin/env python3
"""Build Bubbles and sideload it onto connected iPhones (free Apple account, by cable or Wi-Fi).

  ios/scripts/sideload.py                 # one phone connected: just do it; several: pick one
  ios/scripts/sideload.py --list          # show phones and what is blocking each
  ios/scripts/sideload.py --device 4F2A   # UDID prefix or phone name
  ios/scripts/sideload.py --all --exclude 00008140   # every phone except mine
  ios/scripts/sideload.py --replace       # remove a copy of Bubbles signed by someone else first

It checks pairing, Developer Mode, iOS version, signing, the free-account limits and the
"untrusted developer" step, and waits for the person holding the phone instead of failing.
"""
import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
PROJECT = IOS / "Bubbles.xcodeproj"
SCHEME = "Bubbles"
DERIVED = IOS / "build"
APP = DERIVED / "Build/Products/Debug-iphoneos/Bubbles.app"
POLL = 5


class Fail(Exception):
    """A problem with a plain-language fix for the person running the script."""


def say(msg=""):
    print(msg, flush=True)


def step(msg):
    say(f"\n==> {msg}")


# ---------- toolchain ----------

def find_developer_dir():
    if os.environ.get("DEVELOPER_DIR"):
        return os.environ["DEVELOPER_DIR"]
    try:
        cur = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        cur = ""
    if ".app/Contents/Developer" in cur and Path(cur).exists():
        return cur
    candidates = [Path("/Applications/Xcode.app/Contents/Developer")]
    found = subprocess.run(["mdfind", "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"],
                           capture_output=True, text=True).stdout.split("\n")
    candidates += [Path(p) / "Contents/Developer" for p in found if p.strip()]
    for c in candidates:
        if (c / "usr/bin/xcodebuild").exists():
            return str(c)
    raise Fail("Full Xcode is not installed (only Command Line Tools). Install Xcode from the App Store, open it once, then rerun.")


ENV = dict(os.environ)


def run(cmd, timeout=900, stream=False):
    """Run a command; return (exit code, combined output)."""
    try:
        if not stream:
            p = subprocess.run(cmd, capture_output=True, text=True, env=ENV, timeout=timeout)
            return p.returncode, (p.stdout or "") + (p.stderr or "")
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV)
        out, start = [], time.time()
        for line in p.stdout:
            out.append(line)
            if re.search(r"error:|\*\* BUILD|Signing Identity|Provisioning Profile", line):
                say("   " + line.rstrip())
            if time.time() - start > timeout:
                p.kill()
                return 124, "".join(out) + "\nTimed out."
        return p.wait(), "".join(out)
    except subprocess.TimeoutExpired as e:
        return 124, f"{e.stdout or ''}{e.stderr or ''}\nTimed out after {timeout}s."


# ---------- devices ----------

def norm(s):
    s = unicodedata.normalize("NFKC", s or "").replace("’", "'").replace("‘", "'")
    return s.casefold().strip()


def list_phones():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        path = f.name
    try:
        code, out = run(["xcrun", "devicectl", "list", "devices", "--json-output", path, "-q"], timeout=60)
        if code != 0:
            raise Fail(f"Could not list devices:\n{out.strip()}")
        data = json.load(open(path))
    finally:
        os.unlink(path)
    phones = []
    for d in data.get("result", {}).get("devices", []):
        hw, dp, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
        if hw.get("reality") != "physical" or hw.get("platform") != "iOS":
            continue
        phones.append({
            "name": dp.get("name") or "iPhone",
            "udid": hw.get("udid") or d.get("identifier"),
            "model": hw.get("marketingName") or hw.get("productType") or "?",
            "kind": hw.get("deviceType") or "iPhone",
            "os": dp.get("osVersionNumber"),
            "pairing": cp.get("pairingState"),
            "devmode": dp.get("developerModeStatus"),
            "transport": cp.get("transportType"),
            "tunnel": cp.get("tunnelState"),
        })
    return phones


def phone_by_udid(udid):
    return next((p for p in list_phones() if p["udid"] == udid), None)


def label(p):
    return f"{p['name']} ({p['model']}, …{p['udid'][-6:]})"


def connection(p):
    if p["transport"] == "wired":
        return "USB"
    if p["transport"] == "localNetwork":
        return "Wi-Fi" if p["tunnel"] == "connected" else "Wi-Fi (asleep/away?)"
    return p["transport"] or "?"


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "")[:3]) or (0,)


def blockers(p, min_ios):
    out = []
    if p["pairing"] != "paired":
        out.append("not trusted: unlock it and tap Trust This Computer")
    if p["pairing"] == "paired" and not p["transport"]:
        out.append("not reachable: unlock it / plug it in")
    if p["devmode"] == "disabled":
        out.append("Developer Mode off")
    if p["os"] and vtuple(p["os"]) < vtuple(min_ios):
        out.append(f"iOS {p['os']} is older than the required {min_ios}")
    return out


def print_table(phones, min_ios):
    for i, p in enumerate(phones, 1):
        b = blockers(p, min_ios)
        status = "ready" if not b else "; ".join(b)
        say(f"  {i}. {p['name']:<20} {p['model']:<18} iOS {p['os'] or '?':<8} {connection(p):<8} {p['udid']}  [{status}]")


def wait_for(check, seconds, waiting_msg):
    """Poll check() until truthy or timeout. Prints waiting_msg once."""
    deadline = time.time() + seconds
    shown = False
    while True:
        r = check()
        if r or time.time() >= deadline:
            return r
        if not shown:
            say(f"   … {waiting_msg} (waiting up to {seconds}s, Ctrl-C to stop)")
            shown = True
        time.sleep(POLL)


def pick_phones(args, min_ios):
    phones = list_phones()
    if not phones:
        phones = wait_for(list_phones, args.wait,
                          "No iPhone found. Plug the phone into this Mac with a cable and unlock it") or []
    if not phones:
        raise Fail("No iPhone connected. Use a data cable (not charge-only), unlock the phone, tap Trust, and rerun.")

    excl = [norm(x) for x in args.exclude]
    phones = [p for p in phones if not any(p["udid"].lower().startswith(x) or norm(p["name"]) == x for x in excl)]
    if not phones:
        raise Fail("Every connected phone was excluded.")

    if args.device:
        key = norm(args.device)
        hits = [p for p in phones if p["udid"].lower().startswith(key)] or \
               [p for p in phones if norm(p["name"]) == key] or \
               [p for p in phones if key in norm(p["name"])]
        if not hits:
            say("Connected phones:")
            print_table(phones, min_ios)
            raise Fail(f"No phone matches '{args.device}'.")
        if len(hits) > 1:
            say("Several phones match:")
            print_table(hits, min_ios)
            raise Fail("Pass part of the UDID with --device instead of the name.")
        return hits
    if args.all or len(phones) == 1:
        return phones

    say("Several phones are connected:")
    print_table(phones, min_ios)
    if not sys.stdin.isatty():
        raise Fail("Choose one with --device <UDID prefix or name>, or use --all (with --exclude for yours).")
    while True:
        ans = input("Install on which? (numbers separated by spaces, or 'a' for all): ").strip().lower()
        if ans == "a":
            return phones
        try:
            idx = sorted({int(x) for x in ans.split()})
            if idx and all(1 <= i <= len(phones) for i in idx):
                return [phones[i - 1] for i in idx]
        except ValueError:
            pass
        say("   Not a valid choice.")


# ---------- project ----------

def deployment_target():
    m = re.search(r'iOS:\s*"?([\d.]+)', (IOS / "project.yml").read_text())
    if m:
        return m.group(1)
    code, out = run(["xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME, "-showBuildSettings"], timeout=120)
    m = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+)", out)
    return m.group(1) if m else "0"


def profile_info():
    prov = APP / "embedded.mobileprovision"
    if not prov.exists():
        return None
    raw =subprocess.run(["security", "cms", "-D", "-i", str(prov)], capture_output=True).stdout
    try:
        return plistlib.loads(raw)
    except Exception:
        return None


def bundle_id():
    info = APP / "Info.plist"
    try:
        return plistlib.load(open(info, "rb"))["CFBundleIdentifier"]
    except Exception:
        m = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", (IOS / "project.yml").read_text())
        return m.group(1) if m else None


# ---------- preflight ----------

def preflight(p, min_ios, wait):
    udid = p["udid"]

    if p["os"] and vtuple(p["os"]) < vtuple(min_ios):
        raise Fail(f"{label(p)} runs iOS {p['os']}; Bubbles needs iOS {min_ios} or newer. "
                   "Update it in Settings > General > Software Update, then rerun.")

    if p["pairing"] != "paired":
        say("   Phone is not paired with this Mac. Asking it to pair: unlock the phone and tap Trust, then enter the passcode.")
        run(["xcrun", "devicectl", "manage", "pair", "--device", udid], timeout=120)
        q = wait_for(lambda: (x := phone_by_udid(udid)) and x["pairing"] == "paired" and x,
                     wait, "Waiting for Trust This Computer on the phone")
        if not q:
            raise Fail("The phone never trusted this Mac. Unplug, replug, unlock, tap Trust, and rerun. "
                       "If no prompt appears: Settings > General > Transfer or Reset iPhone > Reset > Reset Location & Privacy.")
        p = q

    if p["devmode"] == "disabled":
        say("   Developer Mode is off. On the phone: Settings > Privacy & Security > Developer Mode > On, then Restart,")
        say("   and after it reboots, unlock it and tap Turn On. (The switch only appears after the phone has been")
        say("   plugged into a Mac running Xcode; if it is missing, keep it plugged in, unlock it, and reopen Settings.)")
        q = wait_for(lambda: (x := phone_by_udid(udid)) and x["devmode"] == "enabled" and x,
                     max(wait, 300), "Waiting for Developer Mode (the phone will restart)")
        if not q:
            raise Fail("Developer Mode is still off. Turn it on as above and rerun.")
        p = q

    if not p["transport"]:
        # Paired before, but not reachable now (locked, asleep, out of Wi-Fi range, or unplugged).
        q = wait_for(lambda: (x := phone_by_udid(udid)) and x["transport"] and x,
                     wait, "Phone is paired but not reachable. Unlock it and plug it in (or keep it on the same Wi-Fi)")
        if not q:
            raise Fail("The phone is not reachable. Plug it in with a cable, unlock it, and rerun.")
        p = q

    if p["transport"] == "localNetwork":
        say("   Connected over Wi-Fi. That works, but a cable is faster and more reliable; keep the phone unlocked and nearby.")
    return p


# ---------- build ----------

BUILD_ERRORS = [
    (r"No Accounts|No account for team|requires a development team|No signing certificate|"
     r"doesn't have an account|Your session has expired",
     "Xcode is not signed in for team LMG7RTY598. Open Xcode > Settings > Accounts, sign in with your Apple ID "
     "(re-enter the password if it shows an error), then rerun.", False),
    (r"maximum App ID limit|App ID limit|exceeded the maximum number of app IDs",
     "Free accounts can create only 10 App IDs per 7 days. Wait for the limit to reset, "
     "or keep the existing bundle ID (do not change PRODUCT_BUNDLE_IDENTIFIER).", False),
    (r"maximum number of registered (devices|iPhone)|device limit",
     "Your Apple account has hit its device limit for this year. Remove nothing yourself; it resets yearly, "
     "or use a paid developer account.", False),
    (r"Developer Mode", "Developer Mode is off on the phone (Settings > Privacy & Security > Developer Mode).", True),
    (r"unpaired|is not paired|pairing", "The phone does not trust this Mac. Unlock it and tap Trust.", True),
    (r"locked|passcode", "The phone is locked. Unlock it and keep it unlocked.", True),
    (r"Unable to find a destination|not available|Preparing|preparing|shared cache|busy|"
     r"Failed to prepare|not connected|timed out|Timed out",
     "Xcode is still preparing the phone for development (first time can take a few minutes). Keep it plugged in and unlocked.", True),
    (r"Failed Registering|Unable to register|not registered|Communication with Apple failed",
     "Xcode could not register the phone with your Apple account. Check the Mac's internet, keep the phone connected, "
     "and if it repeats open Bubbles.xcodeproj in Xcode, choose this phone as the run destination once.", True),
    (r"certificate.*(revoked|expired)|Revoke",
     "Your development certificate is revoked or expired. Xcode > Settings > Accounts > Manage Certificates > + Apple Development.", False),
    (r"minimum (deployment|OS)|requires a newer version of iOS",
     "The phone's iOS is too old for this build.", False),
]


def explain(out, table):
    for pat, msg, transient in table:
        if re.search(pat, out, re.I):
            return msg, transient
    return None, False


def error_lines(out, n=15):
    lines = [l.strip() for l in out.splitlines() if re.search(r"error|failed|Error Domain|reason", l, re.I)]
    return "\n".join(list(dict.fromkeys(lines))[-n:]) or out.strip()[-1500:]


def build(p, retries=3):
    cmd = ["xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME, "-configuration", "Debug",
           "-destination", f"id={p['udid']}", "-derivedDataPath", str(DERIVED),
           "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"]
    for attempt in range(1, retries + 1):
        code, out = run(cmd, timeout=1200, stream=True)
        if code == 0 and "** BUILD SUCCEEDED **" in out and APP.exists():
            return
        msg, transient = explain(out, BUILD_ERRORS)
        if transient and attempt < retries:
            say(f"   {msg} Retrying in 20s ({attempt}/{retries - 1}).")
            time.sleep(20)
            continue
        raise Fail((msg or "Build failed.") + "\n\nDetails:\n" + error_lines(out))


def check_profile(p):
    info = profile_info()
    if not info:
        say("   Warning: could not read the signing profile; continuing.")
        return None
    devices = info.get("ProvisionedDevices")
    if devices is not None and p["udid"] not in devices:
        raise Fail(f"The signing profile does not include {label(p)}, so it would not open. "
                   "Rerun; if it repeats, open the project in Xcode and run once on this phone so it registers.")
    return info


# ---------- install & launch ----------

INSTALL_ERRORS = [
    (r"maximum number of installed apps|free developer profile",
     "Their phone already has 3 apps from free developer accounts (Apple's limit). "
     "Delete one of those sideloaded apps on the phone, then rerun.", "limit"),
    (r"MismatchedApplicationIdentifierEntitlement|does not match.*previously installed|signer.*mismatch|"
     r"upgrade.*different|MismatchedSignature",
     "A copy of Bubbles signed by a different account is already on the phone. Rerun with --replace to remove it "
     "(this deletes that copy's profile data on the phone).", "mismatch"),
    (r"valid provisioning profile.*not found|ApplicationVerificationFailed",
     "The phone rejected the signature (profile missing this phone or expired). Rebuilding.", "rebuild"),
    (r"locked|passcode", "The phone is locked. Unlock it.", "retry"),
    (r"not enough (free )?space|insufficient storage|ENOSPC", "The phone is out of storage. Free up some space and rerun.", "space"),
    (r"Developer Mode", "Developer Mode is off on the phone.", "devmode"),
    (r"could not be found|not connected|timed out|Timed out|Connection|tunnel",
     "Lost the connection to the phone. Keep it plugged in and unlocked.", "retry"),
]


def install(p, args, rebuilt=False):
    for attempt in range(1, 4):
        code, out = run(["xcrun", "devicectl", "device", "install", "app", "--device", p["udid"], str(APP)], timeout=600)
        if code == 0:
            return
        msg, kind = explain(out, INSTALL_ERRORS)
        if kind == "mismatch" and args.replace:
            say("   Removing the other copy of Bubbles first (--replace).")
            run(["xcrun", "devicectl", "device", "uninstall", "app", "--device", p["udid"], bundle_id()], timeout=120)
            continue
        if kind == "rebuild" and not rebuilt:
            say(f"   {msg}")
            build(p)
            check_profile(p)
            return install(p, args, rebuilt=True)
        if kind == "retry" and attempt < 3:
            say(f"   {msg} Retrying in 10s.")
            time.sleep(10)
            continue
        raise Fail((msg or "Install failed.") + "\n\nDetails:\n" + error_lines(out))


def launch(p, args):
    bid = bundle_id()
    cmd = ["xcrun", "devicectl", "device", "process", "launch", "--device", p["udid"], "--terminate-existing", bid]
    told = set()

    def attempt():
        code, out = run(cmd, timeout=120)
        if code == 0:
            return True
        if re.search(r"not been explicitly trusted|invalid code signature|inadequate entitlements", out, re.I):
            if "trust" not in told:
                told.add("trust")
                say("   First run needs one tap on the phone to trust your developer account:")
                say("     Settings > General > VPN & Device Management > (your Apple ID under Developer App) > Trust > Trust")
            return False
        if re.search(r"locked", out, re.I):
            if "lock" not in told:
                told.add("lock")
                say("   The phone is locked; unlock it to open Bubbles.")
            return False
        if "other" not in told:
            told.add("other")
            say("   Could not open Bubbles yet:\n     " + error_lines(out, 4).replace("\n", "\n     "))
        return False

    if wait_for(attempt, args.wait, "Waiting for the phone to trust the app"):
        say("   Bubbles is open on the phone.")
        return True
    say("   Installed, but not opened. After they trust it (steps above) they can tap the Bubbles icon.")
    return False


# ---------- main ----------

def sideload(p, args, min_ios, built_for):
    step(f"{label(p)}  iOS {p['os'] or '?'} via {connection(p)}")
    p = preflight(p, min_ios, args.wait)

    info = profile_info() if APP.exists() else None
    in_profile = info and p["udid"] in (info.get("ProvisionedDevices") or [])
    if args.no_build and in_profile:
        say("   Reusing the existing build (--no-build).")
    elif p["udid"] not in built_for:
        say("   Building and signing for this phone…")
        build(p)
        built_for.add(p["udid"])
    info = check_profile(p)

    say("   Installing…")
    install(p, args)
    opened = launch(p, args) if not args.no_launch else False

    if info and info.get("ExpirationDate"):
        exp = info["ExpirationDate"]
        exp = exp.replace(tzinfo=timezone.utc) if exp.tzinfo is None else exp
        days = (exp - datetime.now(timezone.utc)).total_seconds() / 86400
        when = exp.astimezone().strftime("%a %d %b, %H:%M")
        say(f"   Works until {when} ({days:.1f} days). After that it will not open; plug in and rerun this script."
            + (" (Free account: 7-day limit.)" if days <= 7.5 else ""))
    return opened


def main():
    ap = argparse.ArgumentParser(description="Build Bubbles and sideload it onto connected iPhones.")
    ap.add_argument("--device", help="UDID (or prefix) or phone name")
    ap.add_argument("--all", action="store_true", help="install on every connected phone")
    ap.add_argument("--exclude", action="append", default=[], help="UDID prefix or name to skip (repeatable)")
    ap.add_argument("--list", action="store_true", help="list phones and their status, then exit")
    ap.add_argument("--replace", action="store_true", help="uninstall a Bubbles copy signed by another account first")
    ap.add_argument("--no-build", action="store_true", help="reuse the last build if it already covers the phone")
    ap.add_argument("--no-launch", action="store_true", help="install only")
    ap.add_argument("--wait", type=int, default=180, help="seconds to wait for someone to act on the phone (default 180)")
    args = ap.parse_args()

    try:
        ENV["DEVELOPER_DIR"] = find_developer_dir()
        min_ios = deployment_target()
        if args.list:
            phones = list_phones()
            if not phones:
                say("No physical iPhones connected.")
            else:
                print_table(phones, min_ios)
            return 0
        targets = pick_phones(args, min_ios)
    except Fail as e:
        say(f"\n✗ {e}")
        return 1
    except KeyboardInterrupt:
        say("\nStopped.")
        return 130

    results, built_for = [], set()
    for p in targets:
        try:
            opened = sideload(p, args, min_ios, built_for)
            results.append((p, "installed and opened" if opened else "installed (needs Trust on the phone)" if not args.no_launch else "installed"))
        except Fail as e:
            say(f"\n✗ {label(p)}: {e}")
            results.append((p, "FAILED"))
        except KeyboardInterrupt:
            say("\nStopped.")
            results.append((p, "stopped"))
            break

    step("Summary")
    for p, r in results:
        say(f"  {label(p)}: {r}")
    return 0 if all(r != "FAILED" and r != "stopped" for _, r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
