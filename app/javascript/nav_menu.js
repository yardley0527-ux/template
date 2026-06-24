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
