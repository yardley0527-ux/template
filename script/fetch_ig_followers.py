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
    "shengting.nmnq10",
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
    if os.path.exists(SESSION_FILE):
        try:
            L.load_session_from_file(username, SESSION_FILE)
            print("Loaded cached session")
            return True
        except Exception:
            pass

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
    if ig_user and ig_pass:
        login(L, ig_user, ig_pass)

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
