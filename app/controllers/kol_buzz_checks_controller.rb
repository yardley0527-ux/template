# path: app/controllers/kol_buzz_checks_controller.rb
# frozen_string_literal: true

class KolBuzzChecksController < ApplicationController
  def create
    @candidate = KolCandidate.find(params[:kol_candidate_id])
    check = @candidate.kol_buzz_checks.new(check_params)

    if check.save
      redirect_to @candidate, notice: "已新增聲量查核紀錄"
    else
      redirect_to @candidate, alert: check.errors.full_messages.join("、")
    end
  end

  def destroy
    @candidate = KolCandidate.find(params[:kol_candidate_id])
    @candidate.kol_buzz_checks.find(params[:id]).destroy
    redirect_to @candidate, notice: "已刪除該筆查核紀錄"
  end

  private

  def check_params
    params.require(:kol_buzz_check).permit(:source, :summary, :sentiment, :checked_by, :checked_at, raw_links: [])
  end
end
