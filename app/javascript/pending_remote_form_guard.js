// 保護「勾選checkbox/改下拉選單/填日期就用AJAX自動存檔」的欄位（見
// kocs/relove_kocs/.../kol_contacts/podcast_contacts 這些 local:false 表單）。
// 處理兩種各自獨立的問題：
//
// 一、離開頁面時還有存檔請求沒跑完
//    使用者連續操作好幾個欄位、在存檔請求還沒跑完前就馬上重新整理或關閉分頁，
//    那些「來不及存完」的請求會被瀏覽器直接中斷、資料會遺失，畫面上卻完全
//    沒有任何提示——這是 2026-09-16 使用者第一次回報「勾選後重新整理資料
//    不見」的根因。用 Rails UJS 的 ajax:beforeSend / ajax:complete 事件追蹤
//    「還有幾個請求正在跑」，>0 時在 beforeunload 掛原生確認視窗。
//
// 二、存檔請求本身失敗（跟上面「來不及跑完」不同，這是「跑完了但失敗」）
//    checkbox/select/date這類欄位改了值後，畫面上的打勾/選取狀態是瀏覽器
//    表單元件自己的原生行為，跟背後那個AJAX PATCH有沒有真的成功完全無關
//    ——如果PATCH因為任何原因失敗（CSRF token過期、網路問題、伺服器驗證
//    失敗…），畫面會「看起來已經改了」但資料庫其實沒存到，使用者完全看
//    不出異狀。2026-09-16 使用者實際遇到這個狀況（akimia_kocs一筆KOC勾了
//    3個checkbox，資料庫查證後3個都還是false）。
//    做法：欄位在使用者互動前先把「目前這個值」記在 dataset.savedValue上，
//    當作「已確認存進資料庫的值」；ajax:success時更新這個記錄；ajax:error
//    時把欄位視覺復原成上一個已確認存檔的值，並在欄位旁邊跳出簡短紅字
//    提示幾秒鐘，讓使用者確實知道這次沒存到、需要重新操作一次。
(function () {
  var pendingCount = 0;

  function beforeUnloadHandler(e) {
    e.preventDefault();
    e.returnValue = "";
    return "";
  }

  function updateGuard() {
    if (pendingCount > 0) {
      window.addEventListener("beforeunload", beforeUnloadHandler);
    } else {
      window.removeEventListener("beforeunload", beforeUnloadHandler);
    }
  }

  function isTrackedField(el) {
    return el && (el.matches('input[type="checkbox"]') || el.matches("select") || el.matches('input[type="date"]'));
  }

  function currentValue(field) {
    return field.type === "checkbox" ? String(field.checked) : field.value;
  }

  function applyValue(field, value) {
    if (field.type === "checkbox") {
      field.checked = value === "true";
    } else {
      field.value = value;
    }
  }

  function fieldInForm(form) {
    return form.querySelector('input[type="checkbox"], select, input[type="date"]');
  }

  function showSaveFailedNotice(field) {
    var existing = field.parentElement.querySelector(".js-save-failed-notice");
    if (existing) existing.remove();

    var notice = document.createElement("div");
    notice.className = "js-save-failed-notice small text-danger";
    notice.style.cssText = "position:absolute;white-space:nowrap;z-index:10;background:#fff;border:1px solid #dc3545;border-radius:4px;padding:2px 6px;margin-top:2px;";
    notice.textContent = "存檔失敗，請重試";
    field.parentElement.style.position = field.parentElement.style.position || "relative";
    field.parentElement.appendChild(notice);
    setTimeout(function () {
      notice.remove();
    }, 4000);
  }

  document.addEventListener("ajax:beforeSend", function (e) {
    if (!e.target.matches("form[data-remote]")) return;
    pendingCount += 1;
    updateGuard();
  });

  document.addEventListener("ajax:success", function (e) {
    var form = e.target;
    if (!form.matches("form[data-remote]")) return;
    var field = fieldInForm(form);
    if (field && isTrackedField(field)) {
      field.dataset.savedValue = currentValue(field);
    }
  });

  document.addEventListener("ajax:error", function (e) {
    var form = e.target;
    if (!form.matches("form[data-remote]")) return;
    var field = fieldInForm(form);
    if (field && isTrackedField(field) && field.dataset.savedValue !== undefined) {
      applyValue(field, field.dataset.savedValue);
      showSaveFailedNotice(field);
    }
  });

  document.addEventListener("ajax:complete", function (e) {
    if (!e.target.matches("form[data-remote]")) return;
    pendingCount = Math.max(0, pendingCount - 1);
    updateGuard();
  });

  // 欄位第一次被使用者互動（取得焦點）的當下、值還沒被改動前，先記下
  // 「目前值」當成savedValue的初始基準（這是伺服器渲染出來的原始值）——
  // 一定要在change/click改變值之前記，所以掛在focusin而不是change/click上。
  // 之後每次存檔成功（ajax:success）會把這個值往前推進；失敗時就是復原到
  // savedValue，不是復原到「頁面剛載入時」那個更舊的值。
  document.addEventListener(
    "focusin",
    function (e) {
      var field = e.target;
      if (isTrackedField(field) && field.dataset.savedValue === undefined && field.closest("form[data-remote]")) {
        field.dataset.savedValue = currentValue(field);
      }
    },
    true
  );
})();
