# frozen_string_literal: true

# 某種報告某一天已經推播過的紀錄（topic + report_date 唯一），防止重複發。
class LineDigestDelivery < ApplicationRecord
  # 匯入後要報哪幾天：只報 through（通常是昨天）；through 是星期日（星期一一次匯入五六日）就報五～日。
  # 之前漏發的日子（LINE 額度用完、漏匯入）不自動補，要補到 /line_bot_groups 選日期補發。
  # 五～日裡已經發過的日子不重報；已經發到 through 就只回傳 through 那天（由 deliver_once 擋重複）。
  def self.pending_days(topic, through:)
    first = through.sunday? ? through - 2 : through
    last = where(topic: topic).where(report_date: first..through).maximum(:report_date)
    return through..through if last == through

    last ? (last + 1)..through : first..through
  end

  # 先佔位再發：同時跑兩次只有一個佔得到。block 回傳發送的群組數；
  # 發送失敗就把佔位拿掉，下次還能再發。已發過回 0，force 才重發。
  def self.deliver_once(topic, report_date, force: false)
    unless force
      begin
        create!(topic: topic, report_date: report_date)
      rescue ActiveRecord::RecordNotUnique
        return 0
      end
    end

    begin
      count = yield
    rescue StandardError
      where(topic: topic, report_date: report_date).delete_all unless force
      raise
    end
    upsert({ topic: topic, report_date: report_date, group_count: count }, unique_by: %i[topic report_date])
    count
  end
end
