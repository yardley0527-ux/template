class ManychatLeadsController < ApplicationController
  def index
    @accounts = Manychat::LeadReport.accounts
    @account = params[:account].presence_in(@accounts) || @accounts.first
    @to = params[:to].present? ? Date.parse(params[:to]) : Date.current
    @from = params[:from].present? ? Date.parse(params[:from]) : @to - 13
    @status = params[:status].presence_in(Manychat::LeadReport::STATUSES.keys)

    @report = Manychat::LeadReport.new(account: @account, from: @from, to: @to, source: params[:source])
    @leads = @status ? @report.leads.select { |l| l.status == @status } : @report.leads
  rescue Date::Error
    redirect_to manychat_leads_path, alert: "日期格式錯誤"
  end
end
