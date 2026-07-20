import instaloader
import json
import os
import time
from datetime import date

ACCOUNTS = [
    "chloechao0527",
    "shengting_official",
    "shengting.collagen",
    "shengting.vitaminbczinc",
    "shengting.bodyfit",
    "shengting.slim",
    "shengting.hercare",
    "shengting.vitaminDbone",
    "shengting.metabolic",
    "shengting.fishoil",
    "shengting.probiotic",
    "shengting.glow",
    "shengting.light",
    "shengting.eyeprotect",
]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_FILE = os.path.join(REPO_ROOT, "data", "ig_followers_data.json")
SESSION_FILE = os.path.join(REPO_ROOT, ".ig_session")


def load_data():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_data(data):
    with open(DATA_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def login(L, username, password):
    # 1. Cached session file
    if os.path.exists(SESSION_FILE):
        try:
            L.load_session_from_file(username or "cached", SESSION_FILE)
            actual = L.test_login()
            if actual:
                L.context.username = actual
                print(f"Loaded cached session ({actual})")
                return True
            print("Cached session expired")
        except Exception as e:
            print(f"Cached session unusable: {e}")

    # 2. Instagram session from Chrome (avoids checkpoint challenges)
    try:
        import browser_cookie3

        cj = browser_cookie3.chrome(domain_name="instagram.com")
        cookies = {c.name: c.value for c in cj}
        if cookies.get("sessionid"):
            L.context.update_cookies(cookies)
            actual = L.test_login()
            if actual:
                L.context.username = actual
                L.save_session_to_file(SESSION_FILE)
                print(f"Imported session from Chrome ({actual})")
                return True
        print("No active Instagram session in Chrome")
    except Exception as e:
        print(f"Chrome cookie import failed: {e}")

    # 3. Password login (may trigger a checkpoint challenge)
    if not (username and password):
        return False
    try:
        L.login(username, password)
        L.save_session_to_file(SESSION_FILE)
        print(f"Logged in as {username}")
        return True
    except Exception as e:
        print(f"Login failed: {e}")
        return False


def main():
    L = instaloader.Instaloader(
        quiet=True,
        download_pictures=False,
        download_videos=False,
        download_video_thumbnails=False,
        download_geotags=False,
        download_comments=False,
        save_metadata=False,
        request_timeout=30,
    )

    ig_user = os.environ.get("IG_USERNAME")
    ig_pass = os.environ.get("IG_PASSWORD")
    if not login(L, ig_user, ig_pass):
        print("WARNING: proceeding without login; business accounts will fail")

    data = load_data()
    today = str(date.today())

    for i, account in enumerate(ACCOUNTS):
        print(f"Fetching {account}...")
        try:
            profile = instaloader.Profile.from_username(L.context, account)
            followers = profile.followers

            if account not in data:
                data[account] = []
            entries = data[account]
            if entries and entries[-1]["date"] == today:
                entries[-1]["followers"] = followers
            else:
                entries.append({"date": today, "followers": followers})

            print(f"  ✓ {account}: {followers:,}")
        except instaloader.exceptions.TooManyRequestsException:
            print(f"  ✗ {account}: 429 rate limited, skipping")
        except Exception as e:
            print(f"  ✗ {account}: {e}")

        if i < len(ACCOUNTS) - 1:
            time.sleep(5)

    save_data(data)
    print(f"\nDone! Data saved to {DATA_FILE}")


if __name__ == "__main__":
    main()
