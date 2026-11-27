# frozen_string_literal: true

# 回覆助手的詢問紀錄：所有員工問過的問題與回覆，可依員工篩選，給老闆檢視。
# 獨立一個 controller，頁面權限可以跟「回覆助手」分開給。
class ChloeReplyLogsController < ApplicationController
  PER_PAGE = 50

  def index
    @askers = User.where(id: ReplyDraft.distinct.select(:created_by_user_id)).order(:username)
    @asker_counts = ReplyDraft.group(:created_by_user_id).count
    @user_id = params[:user_id].presence&.to_i
    scope = ReplyDraft.includes(:created_by).recent
    scope = scope.where(created_by_user_id: @user_id) if @user_id
    @total = scope.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @page = params[:page].to_i.clamp(1, @total_pages)
    @drafts = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end
end
