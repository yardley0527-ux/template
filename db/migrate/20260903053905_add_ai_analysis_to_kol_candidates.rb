class AddAiAnalysisToKolCandidates < ActiveRecord::Migration[7.1]
  def change
    add_column :kol_candidates, :ai_analysis, :text
    add_column :kol_candidates, :ai_analysis_updated_at, :datetime
  end
end
