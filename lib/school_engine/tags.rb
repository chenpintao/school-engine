# frozen_string_literal: true

module SchoolEngine
  # 表达空间固定标签种子（幂等）
  module Tags
    EXPRESSION_TAGS = %w[碎碎念 今日分享 求助 匿名树洞 校园记录].freeze

    # 幂等创建 5 个固定标签；功能关闭时不处理；返回标签数组
    def self.ensure_tags!
      return [] unless SiteSetting.school_engine_tags_enabled

      EXPRESSION_TAGS.map { |name| Tag.find_or_create_by!(name: name) }
    end
  end
end
