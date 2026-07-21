# frozen_string_literal: true

# Advisory lock for NotificationEngine runs, mirroring
# ShoplineOrdersMaintenanceLock (see that file for the full non-blocking
# rationale — same pattern, separate lock name so notification generation
# and shopline_orders maintenance never contend with each other unnecessarily).
module NotificationsMaintenanceLock
  NAME = "notifications_generate"

  def self.try_with_lock
    conn = ActiveRecord::Base.connection
    key = conn.quote(NAME)
    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{key}))")
    )
    return [false, nil] unless acquired

    begin
      [true, yield]
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{key}))")
    end
  end
end
