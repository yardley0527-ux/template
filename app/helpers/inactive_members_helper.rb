# frozen_string_literal: true

module InactiveMembersHelper
  def im_expiry_class(days_left)
    if days_left < 0
      "im-expiry-gone"
    elsif days_left <= 30
      "im-expiry-warn"
    else
      "im-expiry-ok"
    end
  end
end
