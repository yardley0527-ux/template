class WelcomeController < ApplicationController
  def index
    @snapshot = CommandCenterSnapshot.call
    SyncDepartmentSheetsJob.schedule_if_stale
  end

  def birthday_customers
    today = Date.today
    dates = (today..today + 6.days).to_a

    # 用 month+day 比對，跨月份也正確
    conditions = dates.map do |d|
      "(EXTRACT(month FROM birthdate) = #{d.month}" \
      " AND EXTRACT(day FROM birthdate) = #{d.day})"
    end.join(" OR ")

    customers = ShoplineCustomer
      .where.not(birthdate: nil)
      .where(conditions)
      .select(:id, :full_name,
              :birthdate, :membership_level,:instagram_account)
      .order(Arel.sql(
        "EXTRACT(month FROM birthdate), EXTRACT(day FROM birthdate)"
      ))

    render json: customers.map { |c|
      {
        id:               c.id,
        full_name:        c.full_name,
        membership_level: c.membership_level,
        birthday:         c.birthdate&.strftime("%m/%d"),
        is_today:         c.birthdate&.month == today.month &&
                          c.birthdate&.day   == today.day,
        instagram_account: c.instagram_account.presence
      }
    }
  end
end