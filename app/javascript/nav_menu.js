// Sidebar parent items with children use href="#" as a placeholder (they only
// group child links, e.g. "業配名單", "CRM 效益分析"). Without this handler the
// click falls through to Turbolinks, which resolves "#" against the current
// URL and re-visits the current page instead of expanding the submenu.
document.addEventListener("click", function (e) {
  var link = e.target.closest('#js-nav-menu a[href="#"]');
  if (!link) return;

  var li = link.parentElement;
  if (!li || !li.querySelector(":scope > ul")) return;

  e.preventDefault();
  li.classList.toggle("open");
});

// 手機版點選側邊欄裡的真實連結（例如「每日訂單明細」）navigate 到下一頁時，
// Turbolinks 只換頁面內容、不會重新整理整個瀏覽器分頁，vendor JS 加在 <body> 上的
// "mobile-nav-on" class（控制側邊欄是否展開）會直接被原封不動地帶到下一頁，導致
// 使用者換到新頁面時側邊欄還卡著沒收合。在真的要離開這一頁的當下就先關掉——
// 不能掛在 turbolinks:load 上做，因為漢堡選單按鈕自己也是 href="#"，點它開合
// 側邊欄一樣會觸發 turbolinks:load（同頁錨點導覽），掛在那裡會在使用者剛打開
// 側邊欄的瞬間又把它關掉；用 click 只鎖定「側邊欄裡指向別的頁面的真實連結」就
// 不會誤觸。
document.addEventListener("click", function (e) {
  var link = e.target.closest('.page-sidebar a[href]:not([href="#"])');
  if (!link) return;

  document.body.classList.remove("mobile-nav-on");
});

// 手機版點側邊欄連結換頁後，漢堡選單會整個失效（不是只有上面那個「還卡著沒收合」
// 的小問題）：SmartAdmin 範本自己的初始化只在整頁重新整理（DOMContentLoaded）時
// 跑一次，Turbolinks 換頁不會重新觸發，換頁後即使 document.body 節點沒變、範本
// 綁在它上面的委派點擊監聽器理論上還在，選單按鈕實際上還是點不動，確切卡在
// 範本裡哪一段還沒查出來——範本被壓縮過又沒有文件，要查清楚風險是可能得動到
// 影響全站互動的共用初始化流程。改用更直接、可預期的做法：手機版寬度下
// （< 992px，跟漢堡選單按鈕自己 hidden-lg-up 用的斷點一致）點側邊欄裡的真實連結，
// 直接放棄 Turbolinks 的軟導覽，讓瀏覽器做完整換頁——跟點一般連結、輸入網址進來
// 的效果一樣，一定會重新觸發 DOMContentLoaded、讓範本整套初始化重新跑一次，
// 選單保證正常。用 capture phase 綁，確保比 Turbolinks 自己（bubble phase）
// 更早設定 data-turbolinks="false"。桌面版（≥992px）不受影響，沿用原本的
// Turbolinks 快速換頁。
document.addEventListener(
  "click",
  function (e) {
    if (window.innerWidth >= 992) return;

    var link = e.target.closest('.page-sidebar a[href]:not([href="#"])');
    if (!link) return;

    link.setAttribute("data-turbolinks", "false");
  },
  true
);
