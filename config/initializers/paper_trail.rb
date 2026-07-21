# frozen_string_literal: true

# versions 表的 object/object_changes 是 text 欄位；用 JSON serializer
# 避免 YAML safe_load 的 permitted classes 問題（Date 等型別）。
PaperTrail.serializer = PaperTrail::Serializers::JSON
