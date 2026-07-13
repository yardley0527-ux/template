# frozen_string_literal: true

# 直播準備雷達（近似版）：下一場直播的 title 經產品別名字典解析出產品，
# 再掃各部門近 3 天日誌原文找相關提及。
#
# 這是「疑似相關」的關鍵字比對，不是完成度判斷——部門提到「美白」可能是
# 客訴不是備播，所以結果只呈現提及次數＋證據句，判斷留給人。
class CampaignReadinessScan
  LOOKBACK_DAYS = 3
  MAX_EVIDENCE_PER_DEPT = 3

  # 雷達只看跟檔期執行有關的部門（財務部不在其中）
  DEPARTMENTS = CalendarEvent::DEPARTMENTS

  def self.call
    new.call
  end

  def call
    livestream = next_livestream
    return nil if livestream.nil?

    products = products_in_title(livestream.title)
    {
      livestream:  livestream,
      products:    products.map { |p| p[:label] },
      departments: scan_departments(products)
    }
  end

  private

  def next_livestream
    CalendarEvent.where(event_type: "livestream")
                 .where(event_date: Date.current..)
                 .order(:event_date, :created_at)
                 .first
  end

  # title 包含哪些產品：比對 CrmProduct label 與 active alias。
  # 回傳 [{ label:, terms: [比對用詞...] }]
  def products_in_title(title)
    CrmProduct.confirmed.includes(:active_aliases).filter_map do |product|
      terms = ([product.label] + product.active_aliases.map(&:alias_name)).uniq
      matched = terms.any? { |term| title.include?(term) }
      { label: product.label, terms: terms } if matched
    end
  end

  def scan_departments(products)
    return [] if products.empty?

    terms = products.flat_map { |p| p[:terms] }.uniq
    range = (Date.current - LOOKBACK_DAYS + 1)..Date.current
    updates_by_dept = DepartmentUpdate.in_range(range).group_by(&:department)

    DEPARTMENTS.map do |dept|
      evidence = []
      (updates_by_dept[dept] || []).sort_by(&:log_date).reverse_each do |update|
        update.content.to_s.split("\n").each do |line|
          next unless terms.any? { |term| line.include?(term) }

          evidence << { date: update.log_date, line: line.strip[0, 120] }
        end
      end

      {
        department: dept,
        mentions:   evidence.size,
        evidence:   evidence.first(MAX_EVIDENCE_PER_DEPT)
      }
    end
  end
end
