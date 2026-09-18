# frozen_string_literal: true

module SchoolEngine
  # 全校表达空间（由原 confess 表白墙分类改造）
  #
  # 与旧"整分类强制匿名"机制的区别：
  #  - 主题 OP 一律显示昵称；仅回帖（post_number > 1）可由作者选择匿名
  #  - 匿名回帖在话题内拥有固定字母标签（anon_label = A/B/C…），显示"匿名同学X"
  #  - 历史匿名帖（anonymous=true 无 anon_label）继续整体掩码为"匿名用户"
  module Expression
    # advisory lock 一级 key（"SENG" 缩写派生的固定 int，避免与其它插件冲突）
    ADVISORY_LOCK_KEY = 0x53454e47

    # 表达空间分类（按 site setting 的 slug 查找）
    def self.category
      slug = SiteSetting.school_engine_expression_category.to_s.strip
      slug.present? ? Category.find_by(slug: slug) : nil
    end

    def self.category?(category)
      return false if category.nil?
      category.slug == SiteSetting.school_engine_expression_category.to_s.strip
    end

    # Post 是否位于表达空间
    def self.in_expression?(post)
      category?(post&.topic&.category)
    end

    # 用户是否允许在表达空间匿名（非 staff、非教师；毕业生/学生均可）
    def self.user_may_anonymous?(user)
      return false if user.nil? || user.staff?
      !SchoolEngine::Visibility.teacher?(user)
    end

    # 判定一个新建 post 是否应匿名（供 post_created 钩子统一调用）
    def self.post_wants_anonymous?(post, opts)
      in_expression?(post) &&
        post.post_number > 1 &&
        (opts || {})[:school_anonymous].to_s == "true" &&
        user_may_anonymous?(post.user)
    end

    # 为匿名回帖分配话题内字母标签，写 post.custom_fields["anon_label"]
    # 规则：同一用户在同一话题复用已有字母；新用户按 A、B、C… 首次匿名顺序分配
    # 使用两键咨询锁（话题级），避免并发匿名回帖争用同一字母
    def self.assign_anon_label!(post)
      Topic.transaction do
        Topic.connection.execute(
          "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY}, #{post.topic_id.to_i})",
        )
        existing =
          PostCustomField
            .joins("JOIN posts ON posts.id = post_custom_fields.post_id")
            .where(posts: { topic_id: post.topic_id })
            .where(name: "anon_label")
            .pluck(:user_id, :value)
            .to_h
        existing_label = existing[post.user_id]
        if existing_label.present?
          # 同一用户在同一话题复用已有字母（同人线索）
          post.custom_fields["anon_label"] = existing_label
        else
          used = existing.values.map { |v| v.to_s.strip.upcase }.to_set
          label = ("A".."Z").find { |c| used.exclude?(c) }
          label = "Z#{[used.length - 25, 1].max}" if label.nil?
          post.custom_fields["anon_label"] = label
        end
      end
    end

    # 虚拟用户（带标签，供 participants 等 User 级字段使用）
    def self.labeled_user(label)
      name = "匿名同学#{label}"
      ::User.new(id: -1, username: name, name: name)
    end
  end
end
