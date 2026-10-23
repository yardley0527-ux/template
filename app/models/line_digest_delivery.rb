# frozen_string_literal: true

# 某種報告某一天已經推播過的紀錄（topic + report_date 唯一），防止重複發。
class LineDigestDelivery < ApplicationRecord
end
