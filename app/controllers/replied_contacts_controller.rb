# path: app/controllers/replied_contacts_controller.rb
# frozen_string_literal: true

# 8 個業配／聯絡名單（6 個品牌 KOC 名單 + Podcast + KOL、藝人）共用同一套
# 「聯絡狀態」欄位。「已回覆」是要追蹤後續進度的人，這頁把他們從 8 張表裡
# 撈出來合併成一份清單，點進去還是導回各自名單頁編輯——不重造一套跨品牌
# 的編輯介面（沿用 koc_search 的作法）。
class RepliedContactsController < ApplicationController
  STATUS = "已回覆".freeze

  LISTS = [
    { model: Koc,             label: "Hiff",       path_helper: :kocs_path },
    { model: ReloveKoc,       label: "Relove",     path_helper: :relove_kocs_path },
    { model: BodyGoalsKoc,    label: "Body Goals", path_helper: :body_goals_kocs_path },
    { model: BetterbioKoc,    label: "好好生醫",   path_helper: :betterbio_kocs_path },
    { model: DianbopopoKoc,   label: "Dianbopopo", path_helper: :dianbopopo_kocs_path },
    { model: AkimiaKoc,       label: "微電流面膜", path_helper: :akimia_kocs_path },
    { model: PodcastContact,  label: "Podcast",    path_helper: :podcast_contacts_path },
    { model: KolContact,      label: "KOL、藝人",  path_helper: :kol_contacts_path }
  ].freeze

  def index
    @results = LISTS.filter_map do |list|
      records = list[:model].where(status: STATUS).order(:ig_username)
      next if records.empty?

      { label: list[:label], records: records, path: public_send(list[:path_helper], status: STATUS) }
    end
    @total_count = @results.sum { |r| r[:records].size }
  end
end
