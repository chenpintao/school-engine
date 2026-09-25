# frozen_string_literal: true

module SchoolEngine
  # 分类级匿名规则（Discourse 原生站点设置维护，无自定义配置页）。
  #
  # 存储：SiteSetting.school_engine_category_rules（list 型，每行 "slug:mode"）
  #   confess:optional
  #   anonymous-wall:forced
  # mode：
  #   forced   强制：主题 OP + 回帖全部匿名（原匿名墙行为）
  #   optional 可选：仅回帖可勾选昵称 / 匿名（原表达空间行为；精选/胶囊只作用于这类分类）
  #   disabled 禁止：该分类不允许匿名
  # 规则完全以站点设置为准（设置默认值见 config/settings.yml，后台可见可删改）；
  # 设置为空时不对任何板块生效。板块由管理员自行创建，插件不强制。
  module CategoryRules
    MODES = %w[forced optional disabled].freeze
    SETTING = :school_engine_category_rules

    # 班级圈板块（xx-class-2029-1 / cz-class-2029-3 等）永远不允许匿名：
    # 群组内发帖一律实名/昵称，设置项中即使误配也不生效
    CLASS_CIRCLE_SLUG_REGEX = %r{\A(?:xx|cz)-class-\d{4}-}

    def self.raw_lines
      # Discourse list 型设置以 "|" 分隔存储；同时兼容换行（textarea 直接粘贴）
      value = SiteSetting.public_send(SETTING)
      lines = value.is_a?(Array) ? value : value.to_s.split(/[|\n]/)
      lines.map { |l| l.to_s.strip }.reject(&:blank?)
    end

    # 有效规则数组（slug 非空、mode 合法；同 slug 后者覆盖前者）
    def self.rules
      lines = raw_lines

      result = {}
      lines.each do |line|
        slug, mode = line.split(":", 2)
        slug = slug.to_s.strip
        mode = mode.to_s.strip
        next if slug.blank? || MODES.exclude?(mode)

        result[slug] = mode
      end
      result.map { |slug, mode| { "slug" => slug, "mode" => mode } }
    end

    # 班级圈板块判定
    def self.class_circle?(category_or_slug)
      slug =
        if category_or_slug.is_a?(::String)
          category_or_slug
        else
          category_or_slug&.slug
        end
      slug.to_s.match?(CLASS_CIRCLE_SLUG_REGEX)
    end

    # 按分类对象或 slug 查模式（"forced" / "optional" / "disabled" / nil）
    # 班级圈板块恒为 disabled（默认且强制不匿名）
    def self.mode_for(category_or_slug)
      slug =
        if category_or_slug.is_a?(::String)
          category_or_slug
        else
          category_or_slug&.slug
        end
      return nil if slug.blank?
      return "disabled" if slug.match?(CLASS_CIRCLE_SLUG_REGEX)

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
  end
end
