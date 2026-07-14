# frozen_string_literal: true

# 佈告欄動作（首頁全公司板＋各部門板共用）。所有帳號都能新增/勾選/刪除。
class BulletinNotesController < ApplicationController
  # 部門板頁：/boards/廣告部
  def board
    @department = params[:department]
    unless DepartmentUpdate::DEPARTMENTS.include?(@department)
      return redirect_to root_path, alert: "沒有這個部門"
    end

    notes = BulletinNote.board(@department)
    @notes_by_section = notes.group_by(&:section)
    @section_names = BulletinSection.names_for(@department, note_sections: @notes_by_section.keys)
    @recent_logs = DepartmentUpdate.where(department: @department)
                                   .order(log_date: :desc).limit(5)
  end

  # 新增自訂板（部門板頁的「新增板子」）
  def create_section
    section = BulletinSection.new(department: params[:department], name: params[:name].to_s.strip)
    if section.save
      redirect_to department_board_path(section.department)
    else
      redirect_to board_path_for(params[:department]),
                  alert: "板子建立失敗：#{section.errors.full_messages.join('、')}"
    end
  end

  # 刪除自訂板（板上的便條一併刪除；固定板不能刪）
  def destroy_section
    section = BulletinSection.find(params[:id])
    BulletinNote.where(department: section.department, section: section.name).delete_all
    section.destroy
    redirect_to department_board_path(section.department)
  end

  def create
    department = normalized_department(params.dig(:bulletin_note, :department))
    note = BulletinNote.new(content: params.dig(:bulletin_note, :content).to_s.strip,
                            department: department,
                            section: params.dig(:bulletin_note, :section).to_s.strip.presence || "周待辦",
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
