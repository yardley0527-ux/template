# frozen_string_literal: true

# 6個品牌業配名單頁（Koc/ReloveKoc/DianbopopoKoc/BetterbioKoc/BodyGoalsKoc/
# AkimiaKoc）各加一個「隱藏」欄位，跟既有的「刪除」並存——隱藏只是預設列表
# 篩掉、資料還在，刪除才是真的從資料庫移除；社群部帳號原本就能刪除，這次
# 一併開放能隱藏（用途：不確定要不要留、但還不想真的刪掉時先隱藏起來）。
class AddHiddenToKocTables < ActiveRecord::Migration[7.1]
  TABLES = %i[kocs relove_kocs dianbopopo_kocs betterbio_kocs body_goals_kocs akimia_kocs].freeze

  def change
    TABLES.each do |table|
      add_column table, :hidden, :boolean, default: false, null: false
    end
  end
end
