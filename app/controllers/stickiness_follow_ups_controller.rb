# 黏著度分析：所有標了客人類型的客人，依客人類型＋卡別分類，
# 在這頁填追蹤備註（與破8000的追蹤分開記），並確認追蹤後是否回購同系列
class StickinessFollowUpsController < ApplicationController
  include StickinessScoping

  def index
    @status     = %w[all pending done].include?(params[:status]) ? params[:status] : 'all'
    @start_date = parse_date(params[:start_date])
    @end_date   = parse_date(params[:end_date]) || @start_date
    @end_date   = @start_date if @start_date && @end_date && @end_date < @start_date

    rows = build_rows

    # 日期區間篩選「最後購買日」
    if @start_date.present?
      rows = rows.select do |r|
        r.last_purchase_date &&
          r.last_purchase_date >= @start_date.beginning_of_day &&
          r.last_purchase_date <= @end_date.end_of_day
      end
    end

    @level_stats = build_level_stats(rows)

    pending, done  = rows.partition { |r| !r.tracked? }
    @total_count   = rows.size
    @pending_count = pending.size
    @done_count    = done.size

    filtered = case @status
               when 'pending' then pending
               when 'done'    then done
               else                rows
               end
    @groups = group_by_customer_type(filtered)
  end

  # 已維護：只有 Admin（owner）可以編輯
  def toggle_maintained
    return head :forbidden unless current_user.admin?

    customer = ShoplineCustomer.find(params[:customer_id])
    profile  = customer.customer_profile || customer.build_customer_profile
    profile.update!(stickiness_maintained: ActiveModel::Type::Boolean.new.cast(params[:value]))

    head :ok
  end

  def upsert_note
    customer = ShoplineCustomer.find(params[:customer_id])
    profile  = customer.customer_profile || customer.build_customer_profile
    note     = params[:note].to_s
    profile.update!(
      stickiness_note: note,
      stickiness_note_edited_by: note.present? ? current_user.username : nil
    )

    head :ok
  end
end
