# frozen_string_literal: true

# 某種報告某一天已經推播過的紀錄（topic + report_date 唯一），防止重複發。
class LineDigestDelivery < ApplicationRecord
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
