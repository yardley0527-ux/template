# frozen_string_literal: true

# 人工覆寫一個週期的剩餘天數或預估用完日，並保留修改來源與時間——
# CrmCustomerProductCycleBuilderService 的 upsert 刻意不覆寫這些欄位，
# 覆寫值會一直保留到下次被明確清除為止。
class CrmCustomerProductCycleOverrideService
  class InvalidOverrideError < StandardError; end

  def self.call(cycle:, remaining_days: nil, finish_date: nil, source:)
    new(cycle: cycle, remaining_days: remaining_days, finish_date: finish_date, source: source).call
  end

  def initialize(cycle:, remaining_days:, finish_date:, source:)
    @cycle          = cycle
    @remaining_days = remaining_days
    @finish_date    = finish_date
    @source         = source
  end

  def call
    raise InvalidOverrideError, "source is required" if @source.blank?
    raise InvalidOverrideError, "remaining_days or finish_date is required" if @remaining_days.blank? && @finish_date.blank?

    @cycle.manual_override_remaining_days = @remaining_days.presence&.to_i
    @cycle.manual_override_finish_date    = @remaining_days.present? ? nil : @finish_date
    @cycle.manual_override_source         = @source
    @cycle.manual_override_at             = Time.current
    @cycle.save!
    @cycle
  end
end
