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
