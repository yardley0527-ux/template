# frozen_string_literal: true

# 方案 B PR4：全能場 IG 折扣碼使用名單。
#
# 個資處理原則：config/livestream_modules/ig_discount_2026_06_05.yml 只存
# 中繼資料（來源／用途／回顧日期），不含姓名／email 等顧客識別資料——那些
# 原本就存在 OmnipotentAnalysisController::IG_DISCOUNT_CODES（PR4 之前已
# commit 的既有常數），這裡直接讀取，不把 PII 複製進第二個 git 追蹤位置。
class IgDiscountCohortLookup
  YAML_PATH = Rails.root.join("config/livestream_modules/ig_discount_2026_06_05.yml")

  class << self
    def event_date
      meta["event_date"]
    end

    def source
      meta["source"]
    end

    def purpose
      meta["purpose"]
    end

    def review_date
      meta["review_date"]
    end

    def entries
      OmnipotentAnalysisController::IG_DISCOUNT_CODES.map(&:stringify_keys)
    end

    def review_due?
      review_date.present? && Date.current >= review_date
    end

    private

    def meta
      @meta ||= load_meta
    end

    def load_meta
      return {} unless File.exist?(YAML_PATH)

      YAML.safe_load_file(YAML_PATH, permitted_classes: [Date], aliases: true)
    rescue StandardError
      {}
    end
  end
end
