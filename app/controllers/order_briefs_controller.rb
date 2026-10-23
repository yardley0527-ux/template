# frozen_string_literal: true

# 每日訂單簡報明細頁：LINE 只發 Flex 總覽，客人明細（回購、第一次買、很久沒回來…）在這裡看。
# 跟 LINE 卡片用同一份 OrderBrief::Report，數字一定一致。預設看昨天（台灣時間）。
class OrderBriefsController < ApplicationController
  def index
    @date = parse_date(params[:date]) || Date.current - 1
    @report = OrderBrief::Report.new(@date)
  end

  private

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
