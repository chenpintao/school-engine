# frozen_string_literal: true

module SchoolEngine
  # 精选机制：staff 每天从表达空间回帖中精选固定条数，展示于首页
  # 精选同时写入时光胶囊标记；取消精选释放当日名额（不回滚胶囊）
  module Featured
    class QuotaExceeded < StandardError
    end

    class NotEligible < StandardError
    end

    CF_FEATURED = "school_featured"
    CF_FEATURED_AT = "school_featured_at"
    CF_CAPSULE = "school_capsule"

    # 仅表达空间分类下的回帖（post_number > 1）可被精选
    def self.eligible?(post)
      return false if post.nil?
      Expression.in_expression?(post) && post.post_number > 1
    end

    def self.featured?(post)
      post.custom_fields[CF_FEATURED] == "true"
    end

    # 服务器时区自然日内已精选条数
    def self.featured_count_today(time = Time.zone.now)
      PostCustomField.where(name: CF_FEATURED_AT).where(
        "value >= :start AND value < :finish",
        start: time.beginning_of_day.utc.iso8601,
        finish: time.end_of_day.utc.iso8601,
      ).count
    end

    # 标记精选（含当日上限校验）；成功返回 true，已精选返回 false
    def self.feature!(post)
      raise NotEligible unless eligible?(post)
      return false if featured?(post)

      if featured_count_today >= SiteSetting.school_engine_featured_per_day.to_i
        raise QuotaExceeded
      end

      now_iso = Time.zone.now.utc.iso8601
      post.custom_fields[CF_FEATURED] = "true"
      post.custom_fields[CF_FEATURED_AT] = now_iso
      post.custom_fields[CF_CAPSULE] = "true" if post.custom_fields[CF_CAPSULE] != "true"
      post.save_custom_fields(true)
      true
    end

    # 取消精选：移除精选标记，释放当日名额；时光胶囊标记保留
    def self.unfeature!(post)
      return false unless featured?(post)
      post.custom_fields.delete(CF_FEATURED)
      post.custom_fields.delete(CF_FEATURED_AT)
      post.save_custom_fields(true)
      true
    end

    # 点赞达阈值自动入时光胶囊（仅非匿名帖；幂等）
    def self.auto_capsule_by_likes!(post)
      return false if post.nil?
      return false if post.custom_fields["anonymous"] == "true"
      return false if post.custom_fields[CF_CAPSULE] == "true"
      return false if Post.where(id: post.id).pick(:like_count).to_i <
                        SiteSetting.school_engine_capsule_like_threshold.to_i
      post.custom_fields[CF_CAPSULE] = "true"
      post.save_custom_fields(true)
      true
    end

    CAPSULE_JOIN_SQL =
      "JOIN post_custom_fields school_pcf_capsule ON school_pcf_capsule.post_id = posts.id " \
        "AND school_pcf_capsule.name = 'school_capsule' AND school_pcf_capsule.value = 'true'"

    ANONYMOUS_EXCLUDE_SQL =
      "posts.id NOT IN (SELECT post_id FROM post_custom_fields WHERE name = 'anonymous' AND value = 'true')"

    # 用户的时光胶囊帖（默认排除匿名帖；私信报告可 include_anonymous: true）
    def self.capsule_posts_for(user, since: nil, include_anonymous: false, limit: 500)
      scope =
        Post
          .joins(:topic)
          .joins(CAPSULE_JOIN_SQL)
          .where(user_id: user.id, hidden: false, deleted_at: nil)
          .where(topics: { deleted_at: nil })
      scope = scope.where("posts.created_at >= ?", since) if since
      scope = scope.where(ANONYMOUS_EXCLUDE_SQL) unless include_anonymous
      scope.order(posts: { created_at: :desc }).limit(limit)
    end

    # 时间窗口内有胶囊内容的用户 id
    def self.user_ids_with_capsule(since:)
      Post
        .joins(CAPSULE_JOIN_SQL)
        .where(hidden: false, deleted_at: nil)
        .where("posts.created_at >= ?", since)
        .distinct
        .pluck(:user_id)
    end

    # 序列化补充：向帖子 JSON 暴露精选状态（供 staff 菜单切换）
    module PostSerializerExtension
      def self.prepended(base)
        base.attributes :school_featured
      end

      def school_featured
        object.custom_fields[CF_FEATURED] == "true"
      end
    end
  end
end
