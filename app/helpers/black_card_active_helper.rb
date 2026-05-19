# frozen_string_literal: true

module BlackCardActiveHelper
  def expiry_badge_class(days_left)
    if days_left < 0
      "bc-expiry-gone"
    elsif days_left <= 30
      "bc-expiry-warn"
    else
      "bc-expiry-ok"
    end
  end
end
