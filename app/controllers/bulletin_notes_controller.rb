# frozen_string_literal: true

# 佈告欄動作（首頁全公司板＋各部門板共用）。所有帳號都能新增/勾選/刪除。
class BulletinNotesController < ApplicationController
  # 部門板頁：/boards/廣告部
  def board
    @department = params[:department]
    unless DepartmentUpdate::DEPARTMENTS.include?(@department)
      return redirect_to root_path, alert: "沒有這個部門"
    end

    @notes = BulletinNote.board(@department)
    @recent_logs = DepartmentUpdate.where(department: @department)
                                   .order(log_date: :desc).limit(5)
  end

  def create
    department = normalized_department(params.dig(:bulletin_note, :department))
    note = BulletinNote.new(content: params.dig(:bulletin_note, :content).to_s.strip,
                            department: department,
                            created_by: current_user&.username)
    if note.save
      redirect_to board_path_for(note.department)
    else
      redirect_to board_path_for(department), alert: "備忘不能是空的（上限 500 字）"
    end
  end

  def toggle
    note = BulletinNote.find(params[:id])
    note.toggle_done!(current_user)
    redirect_to board_path_for(note.department)
  end

  def destroy
    note = BulletinNote.find(params[:id])
    note.destroy
    redirect_to board_path_for(note.department)
  end

  private

  def normalized_department(value)
    DepartmentUpdate::DEPARTMENTS.include?(value) ? value : nil
  end

  def board_path_for(department)
    department.present? ? department_board_path(department) : root_path
  end
end
