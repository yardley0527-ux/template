# frozen_string_literal: true

# 方案 B PR4：直播管理頁面整併後的權限遷移（資料遷移，無 schema 變更）。
#
# 規則（唯一授權依據——沒有舊權限的 role 不會被這支遷移動到任何一列）：
#   有 A 的 role → 補一列 B（find_or_create_by!，冪等）
#   livestreams（直播歷史／直播場次）           → livestream_overview（新首頁，同群組自然延伸）
#   turmeric/metabolism/glutathione/probiotic/
#   omnipotent_analysis（5 個舊產品分析頁其一）  → livestream_product_analysis（共用產品分析頁）
#   livestream_analysis（品牌之夜總覽）          → livestream_strategy（併入「出席與回流」頁籤）
#
# 舊權限列完全不動、不刪。
# admin 行為不變：ApplicationController#authorize_page! 對 admin 一律略過 page_permissions 檢查。
#
# ── 為什麼 down 是 IrreversibleMigration，不是「只刪自己新增的列」──────────
# page_permissions 沒有任何欄位記錄「這一列是誰、何時、為什麼建立的」（沒有
# created_by/source 之類的來源標記，且刻意不為此新增追蹤表）。up 用
# find_or_create_by!，同一個 (role_id, controller_name) 若在 up 執行當下已
# 存在就不會動它、若不存在就新建——這個「新建 vs 本來就有」的判斷只在 up
# 執行的當下、同一個記憶體物件生命週期內成立。一旦 up 執行完、process 結束
# （典型情境：deploy 跑完 migration 後程序就退出了），這個判斷依據就不再存在：
# 之後任何時間點想 rollback，都只能重新掃「現在」符合 OLD_TO_NEW 條件的
# (role, new_controller) 列去刪——但這無法區分「是這次 migration 建立的」
# 還是「migration 跑完之後，某人／某流程獨立把同一個 role 也授權了同一個
# 新 controller」（例如管理者事後手動在這兩者之間任何一個時間點加的）。
# 硬要「只刪自己新增的」在跨 process 的 rollback 情境下無法成立，寧可誠實
# 拒絕，也不要用一個看起來可逆、實際上可能誤刪別人授權的 down。
class MigrateLivestreamPagePermissions < ActiveRecord::Migration[7.1]
  OLD_TO_NEW = {
    "livestreams"          => %w[livestream_overview],
    "turmeric_analysis"    => %w[livestream_product_analysis],
    "metabolism_analysis"  => %w[livestream_product_analysis],
    "glutathione_analysis" => %w[livestream_product_analysis],
    "probiotic_analysis"   => %w[livestream_product_analysis],
    "omnipotent_analysis"  => %w[livestream_product_analysis],
    "livestream_analysis"  => %w[livestream_strategy]
  }.freeze

  class MigrationPagePermission < ActiveRecord::Base
    self.table_name = "page_permissions"
  end

  # 「新建立 vs 執行前就已存在」只在這次 up 呼叫的當下判斷得出來（看
  # find_or_create_by! 之前那個 (role_id, controller_name) 存不存在），
  # 這個判斷結果只用來記錄本次執行摘要（供部署時人工核對），不作為 down
  # 的依據——過了這次 up，這個資訊就沒有持久化的地方可以再問。
  def up
    created = 0
    already_present = 0

    OLD_TO_NEW.each do |old_controller, new_controllers|
      role_ids = MigrationPagePermission.where(controller_name: old_controller).distinct.pluck(:role_id)
      role_ids.each do |role_id|
        new_controllers.each do |new_controller|
          existed_before = MigrationPagePermission.exists?(role_id: role_id, controller_name: new_controller)
          MigrationPagePermission.find_or_create_by!(role_id: role_id, controller_name: new_controller)
          existed_before ? (already_present += 1) : (created += 1)
        end
      end
    end

    say "granted #{created} new page_permission row(s); #{already_present} already present (no-op)"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "此遷移的授權資料是 additive-only：page_permissions 沒有欄位記錄每一列的來源，" \
          "up 執行完（尤其是跨 process/deploy 之後）就無法可靠區分「這是本次遷移新增的」" \
          "還是「之後有人／有流程獨立授權了相同的 (role, controller_name)」。" \
          "若確定要撤銷，請先人工核對 OLD_TO_NEW 對應關係，再手動刪除確認無誤的列。"
  end
end
