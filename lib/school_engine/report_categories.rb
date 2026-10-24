# frozen_string_literal: true

module SchoolEngine
  # 举报分类（需求：违法、欺凌/冷暴力、隐私泄露、人肉、匿名滥用、自伤风险、广告灌水、联系方式骚扰）
  # 固定顺序，前后端共用。code 入库，label 走 I18n。
  module ReportCategories
    CODES = %w[illegal bullying privacy doxxing anon_abuse self_harm spam contact_harassment].freeze

    # 每个分类的默认处置建议（仅作提示，人工可改）
    SUGGESTED_ACTION = {
      "illegal" => "remove_and_report",
      "bullying" => "hide_pending",
      "privacy" => "hide_pending",
      "doxxing" => "remove_and_report",
      "anon_abuse" => "review",
      "self_harm" => "support_and_review",
      "spam" => "fold",
      "contact_harassment" => "hide_pending",
    }.freeze

    # 需要"立即隐藏待复核"（先保护受害者）的分类
    AUTO_HIDE = %w[bullying privacy doxxing contact_harassment].freeze

    def self.valid?(code)
      CODES.include?(code.to_s)
    end

    def self.label(code)
      I18n.t("school_engine.report.categories.#{code}", default: code.to_s)
    end

    # 供前端渲染的分类列表
    def self.for_client
      CODES.map do |code|
        {
          code: code,
          label: label(code),
          hint: I18n.t("school_engine.report.category_hints.#{code}", default: ""),
          auto_hide: AUTO_HIDE.include?(code),
        }
      end
    end
  end
end
