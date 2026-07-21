# frozen_string_literal: true

# 方案 B PR3：唯讀查詢 PR1 一次性回填留下的 db/data/livestream_reconciliation.yml，
# 給單場詳情頁顯示「未納入產品分析品項」。
#
# 這份 YAML 只涵蓋 PR1 回填當下的 45 場；新增場次不在裡面時回傳空陣列（不是
# 錯誤，代表尚未有人工核對過的 unmapped 清單，不是「這場沒有未納入品項」）。
# 內容只在部署時隨程式碼變動，同一個 process 內用類別層級變數記憶一次即可。
class LivestreamReconciliationLookup
  YAML_PATH = Rails.root.join("db/data/livestream_reconciliation.yml")

  class << self
    def unmapped_products_for(date)
      entries[date]&.fetch("unmapped_products", []) || []
    end

    private

    def entries
      @entries ||= load_entries
    end

    def load_entries
      return {} unless File.exist?(YAML_PATH)

      YAML.safe_load_file(YAML_PATH, permitted_classes: [Date], aliases: true)
          .index_by { |e| e["date"] }
    rescue StandardError
      {}
    end
  end
end
