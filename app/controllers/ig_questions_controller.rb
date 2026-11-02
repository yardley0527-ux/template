# IG 未回覆問題：每天的 AI 整理（總結、建議、分類統計、敏感問題）＋完整清單，見 Manychat::QuestionDigest。
class IgQuestionsController < ApplicationController
  def index
    latest = IgQuestion.maximum(:asked_at)&.to_date
    @day = params[:day].present? ? Date.parse(params[:day]) : (latest || Date.current - 1)
    @digest = IgQuestionDigest.find_by(day: @day)
    @questions = IgQuestion.on_day(@day).order(:asked_at)
    @questions = @questions.where(status: params[:status]) if params[:status].in?(IgQuestion::STATUSES.keys)

    day_counts = IgQuestion.on_day(@day).group(:category).count
    prev_counts = IgQuestion.on_day(@day - 1).group(:category).count
    week_counts = IgQuestion.where(asked_at: (@day - 6).beginning_of_day..@day.end_of_day).group(:category).count
    @category_rows = (IgQuestion::CATEGORIES + [nil]).filter_map do |c|
      next if [day_counts, prev_counts, week_counts].all? { |h| h[c].to_i.zero? }

      { category: c || "未分類", day: day_counts[c].to_i, prev: prev_counts[c].to_i, week: week_counts[c].to_i,
        examples: IgQuestion.on_day(@day).where(category: c).order(:asked_at).limit(3).pluck(:question) }
    end.sort_by { |r| [-r[:day], -r[:week]] }
    @total = day_counts.values.sum
    @prev_total = prev_counts.values.sum
    @sensitive = IgQuestion.on_day(@day).where(sensitive: true).order(:asked_at)
    @open_count = IgQuestion.on_day(@day).where(status: "open").count
  rescue Date::Error
    redirect_to ig_questions_path, alert: "日期格式錯誤"
  end

  def update
    question = IgQuestion.find(params[:id])
    question.update!(status: params[:status]) if params[:status].in?(IgQuestion::STATUSES.keys)
    redirect_back fallback_location: ig_questions_path(day: question.asked_at.to_date)
  end

  def regenerate
    day = Date.parse(params[:day])
    IgQuestionDigest.find_or_create_by!(day: day).update!(status: "pending", error_message: nil)
    IgQuestionDigestJob.perform_later(day.iso8601)
    redirect_to ig_questions_path(day: day), notice: "已開始重新整理，約 1–2 分鐘後重新整理頁面"
  end
end
