# frozen_string_literal: true

module SchoolEngine
  # 分类级匿名规则（后台配置页表单维护，不再硬编码"表达空间/匿名墙" slug）。
  #
  # 存储：SiteSetting.school_engine_category_rules，JSON 数组
  #   [{"slug":"confess","mode":"optional"},{"slug":"anonymous-wall","mode":"forced"}]
  # mode：
  #   forced   强制：主题 OP + 回帖全部匿名（原匿名墙行为）
  #   optional 可选：仅回帖可勾选昵称 / 匿名（原表达空间行为；精选/胶囊只作用于这类分类）
  #   disabled 禁止：该分类不允许匿名
  # 设置为空（或解析失败）时使用 DEFAULT_RULES，保证升级后行为与旧硬编码完全一致。
  module CategoryRules
    MODES = %w[forced optional disabled].freeze
    SETTING = :school_engine_category_rules

    DEFAULT_RULES = [
      { "slug" => "confess", "mode" => "optional" },
      { "slug" => "anonymous-wall", "mode" => "forced" },
    ].freeze

    def self.raw_rules
      return nil if SiteSetting.public_send(SETTING).to_s.strip.blank?

      JSON.parse(SiteSetting.public_send(SETTING).to_s)
    rescue JSON::ParserError
      nil
    end

    # 有效规则数组（slug 非空、mode 合法；同 slug 后者覆盖前者）
    def self.rules
      parsed = raw_rules
      return DEFAULT_RULES.map(&:dup) if parsed.nil?
      return [] unless parsed.is_a?(Array)

      result = {}
      parsed.each do |row|
        next unless row.is_a?(Hash)

        slug = row["slug"].to_s.strip
        mode = row["mode"].to_s
        next if slug.blank? || MODES.exclude?(mode)

        result[slug] = mode
      end
      result.map { |slug, mode| { "slug" => slug, "mode" => mode } }
    end

    # 按分类对象或 slug 查模式（"forced" / "optional" / "disabled" / nil）
    def self.mode_for(category_or_slug)
      slug =
        if category_or_slug.is_a?(::String)
          category_or_slug
        else
          category_or_slug&.slug
        end
      return nil if slug.blank?

      rules.find { |rule| rule["slug"] == slug }&.[]("mode")
    end

    def self.forced?(category)
      mode_for(category) == "forced"
    end

    def self.optional?(category)
      mode_for(category) == "optional"
    end

    # 该分类是否存在匿名内容（强制或可选）
    def self.allows_anonymous?(category)
      %w[forced optional].include?(mode_for(category))
    end

    def self.categories_with_mode(mode)
      slugs = rules.select { |rule| rule["mode"] == mode }.map { |rule| rule["slug"] }
      return [] if slugs.empty?

      ::Category.where(slug: slugs).to_a
    end

    # 由配置页提交的行清洗后落库；返回清洗结果（供回显）。
    # 兼容三种入参：JSON 数组 / urlencoded 产生的 {"0"=>{...}} 哈希 / ActionController::Parameters
    def self.update!(rows)
      rows = rows.to_unsafe_h if rows.respond_to?(:to_unsafe_h)
      rows = rows.values if rows.is_a?(Hash)

      cleaned = []
      seen = Set.new
      Array(rows).each do |row|
        row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
        next unless row.is_a?(Hash)

        slug = row["slug"].to_s.strip
        mode = row["mode"].to_s
        next if slug.blank? || MODES.exclude?(mode) || seen.include?(slug)

        seen << slug
        cleaned << { "slug" => slug, "mode" => mode }
      end
      SiteSetting.public_send("#{SETTING}=", JSON.generate(cleaned))
      cleaned
    end
  end
end
