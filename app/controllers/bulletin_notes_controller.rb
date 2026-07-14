# frozen_string_literal: true

# 首頁佈告欄的動作。所有人（各部門帳號）都能新增/勾選/刪除。
class BulletinNotesController < ApplicationController
  def create
    note = BulletinNote.new(content: params.dig(:bulletin_note, :content).to_s.strip,
                            created_by: current_user&.username)
    if note.save
      redirect_to root_path
    else
      redirect_to root_path, alert: "備忘不能是空的（上限 500 字）"
    end
  end

  def toggle
    BulletinNote.find(params[:id]).toggle_done!(current_user)
    redirect_to root_path
  end

  def destroy
    BulletinNote.find(params[:id]).destroy
    redirect_to root_path
  end
end
