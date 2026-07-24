class WelcomeController < ApplicationController
  COVER_ONLY_USERNAMES = %w[crmdata].freeze

  def index
    if COVER_ONLY_USERNAMES.include?(current_user.username)
      render :cover and return
    end

    @snapshot = CommandCenterSnapshot.call

    # 月曆（原「公司行事曆」頁搬進首頁）
    @month = parse_month
    range = @month.beginning_of_month..@month.end_of_month
    @events_by_date = CalendarEvent.in_range_with_livestreams(range).group_by(&:event_date)
    @department_updates_by_date = DepartmentUpdate.in_range(range)
      .sort_by { |u| DepartmentUpdate::DEPARTMENTS.index(u.department) || 99 }
      .group_by(&:log_date)

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

  private

  def parse_month
    Date.strptime(params[:month], "%Y-%m")
  rescue ArgumentError, TypeError
    Date.current.beginning_of_month
  end
end