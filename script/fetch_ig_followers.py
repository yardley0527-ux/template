import instaloader
import json
import os
import sys
import time
import webbrowser
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

# chloechao0527 是個人帳號，session 失效時常常還是抓得到，不能拿來判斷登入是否有效。
# shengting_official 是一定存在的官方帳號，抓不到幾乎可以肯定是 session 死了，不是帳號真的不存在。
CANARY_ACCOUNT = "shengting_official"

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


def session_is_healthy(L):
    # test_login() 只驗證 cookie 格式看起來像已登入，IG 有時候會讓這個檢查過但實際上
    # 商業帳號的資料都抓不到（軟性登出/被判定可疑）——用一個一定存在的帳號實測一次才準。
    try:
        instaloader.Profile.from_username(L.context, CANARY_ACCOUNT)
        return True
    except Exception as e:
        print(f"  健康檢查失敗（{CANARY_ACCOUNT}）：{e}")
        return False


def login(L, username, password):
    # 1. Cached session file
    if os.path.exists(SESSION_FILE):
        try:
            L.load_session_from_file(username or "cached", SESSION_FILE)
            actual = L.test_login()
            if actual:
                L.context.username = actual
                print(f"Loaded cached session ({actual})")
                if session_is_healthy(L):
                    return True
                print("Cached session 已失效（抓不到官方帳號），改嘗試從 Chrome 重新匯入登入資訊...")
            else:
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
            if actual and session_is_healthy(L):
                L.context.username = actual
                L.save_session_to_file(SESSION_FILE)
                print(f"Imported session from Chrome ({actual})")
                return True
        print("No active/healthy Instagram session in Chrome")
    except Exception as e:
        print(f"Chrome cookie import failed: {e}")

    # 3. Password login (may trigger a checkpoint challenge)
    if username and password:
        try:
            L.login(username, password)
            if session_is_healthy(L):
                L.save_session_to_file(SESSION_FILE)
                print(f"Logged in as {username}")
                return True
        except Exception as e:
            print(f"Login failed: {e}")

    # 4. 都失敗了——不要繼續用壞掉的 session 硬跑（會整批「Profile does not exist」，
    # 資料看起來沒更新但也不會有明顯錯誤訊息）。跳出瀏覽器登入頁讓你直接重新登入，
    # 登入完再重新執行一次這支 script 就會用新的 Chrome session。
    print("\n請在跳出的瀏覽器分頁重新登入 Instagram（帳號 serena.ncs），登入完再重新執行一次這個指令。")
    try:
        webbrowser.open("https://www.instagram.com/accounts/login/")
    except Exception:
        pass
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
        print("\n登入失敗，今天不會更新任何資料（避免整批寫入失敗結果蓋掉舊資料）。")
        print("重新登入後再執行一次：python3 script/fetch_ig_followers.py")
        sys.exit(1)

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
