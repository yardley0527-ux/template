# frozen_string_literal: true

# 人工撰寫的週報補充分析：內容放在 config/weekly_manual_reports/YYYY-MM-DD.yml
# （檔名 = 該週週一），/weekly_briefings/:week_start 頁面最上方會顯示。
#
# 為什麼用檔案而不是資料庫：跟 LivestreamReportsController::REPORTS 同一種「程式碼寫死清單」
# 慣例，內容只有彙總數字（不含姓名／email／IG 帳號等個資），不受自動產生報告
# （WeeklyBriefingService 會整列覆蓋 meta／ai_report）影響，也不需要寫正式站資料庫。
#
# YAML 結構：
#   title / prepared_on / scope
#   sections: [{ heading:, blocks: [{ caption:, table: { headers:, rows: }, bullets: [], note: }] }]
class WeeklyManualReport
  DIR = Rails.root.join("config/weekly_manual_reports")

  class << self
    def for(week_start)
      path = DIR.join("#{week_start.to_date.iso8601}.yml")
      return nil unless File.exist?(path)

      load_file(path)
    end

    # [[week_start(Date), title], ...]，新到舊
    def all
      Dir.glob(DIR.join("*.yml")).sort.reverse.filter_map do |path|
        report = load_file(path)
        next if report.blank?

        [Date.iso8601(File.basename(path, ".yml")), report[:title]]
      rescue ArgumentError
        nil
      end
    end

    private

    def load_file(path)
      data = YAML.safe_load_file(path, permitted_classes: [Date], aliases: false)
      data.is_a?(Hash) ? data.with_indifferent_access : nil
    rescue StandardError => e
      Rails.logger.warn("[WeeklyManualReport] #{path}: #{e.class}: #{e.message}")
      nil
    end
  end
end
