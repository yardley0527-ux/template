class ManychatChecksController < ApplicationController
  def index
    @date = params[:date].presence ? Date.parse(params[:date]) : Date.current
    rows = ManychatCheck.rows_for(@date).index_by { |r| [r.account_key, r.time_slot] }

    @grid = ManychatCheck::ACCOUNTS.keys.map do |account_key|
      {
        account_key: account_key,
        label: ManychatCheck::ACCOUNTS[account_key],
        slots: ManychatCheck::TIME_SLOTS.keys.to_h { |slot| [slot, rows[[account_key, slot]]] }
      }
    end
  rescue Date::Error
    redirect_to manychat_checks_path, alert: "日期格式錯誤"
  end

  def update
    check = ManychatCheck.find(params[:id])
    attrs = check_params
    if attrs.key?(:checked)
      if ActiveModel::Type::Boolean.new.cast(attrs[:checked])
        attrs[:checked_by_user_id] = current_user.id
        attrs[:checked_at] = Time.current
      else
        attrs[:checked_by_user_id] = nil
        attrs[:checked_at] = nil
      end
    end
    check.update!(attrs)
    render json: {
      checked: check.checked,
      note: check.note,
      checked_by: check.checked_by&.username,
      checked_at: check.checked_at&.strftime("%m/%d %H:%M")
    }
  end

  private

  def check_params
    params.require(:manychat_check).permit(:checked, :note)
  end
end
