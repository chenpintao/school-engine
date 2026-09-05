# frozen_string_literal: true

module SchoolEngine
  # 匿名机制（自研，不用 Discourse 原生匿名账号）
  #
  # 原理：
  #  - 存储：post.custom_fields["anonymous"] = "true"，user_id 正常保留（管理员可溯源）
  #  - 显示：序列化层伪装——非作者、非管理员看到 "匿名用户" + 默认头像
  #  - 作者本人：看到真实信息；管理员：看到真实信息（可溯源）
  module Anonymous
    ANONYMOUS_NAME = "匿名用户"

    # ===== 查询辅助 =====

    # 该分类是否允许匿名（SiteSetting.school_engine_anonymous_categories 逗号分隔的 slug）
    def self.category_allows_anonymous?(category)
      return false if category.nil?
      slugs = SiteSetting.school_engine_anonymous_categories.to_s.split(",").map(&:strip).reject(&:empty?)
      slugs.include?(category.slug)
    end

    # 帖子是否应匿名（分类在 Topic 上，Post 没有 category 方法）
    def self.post_anonymous?(post)
      return false if post.nil?
      category_allows_anonymous?(post.topic&.category)
    end

    # 当前视角是否应看到匿名（非作者、非管理员）
    def self.mask?(post, scope)
      return false if post.nil?
      return false unless post.custom_fields["anonymous"].present?
      return false if scope.is_staff?
      return false if scope.current_user && scope.current_user.id == post.user_id
      true
    end

    # 用户粒度掩码判定（用于 created_by / last_poster / participants 等 User 级字段）
    def self.mask_user?(user, scope)
      return false if user.nil?
      return false if scope.is_staff?
      return false if scope.current_user && scope.current_user.id == user.id
      true
    end

    # 虚拟匿名用户（列表映射 id=-1 / BasicUser 级序列化复用）
    def self.anon_user
      ::User.new(id: -1, username: ANONYMOUS_NAME, name: ANONYMOUS_NAME)
    end

    # BasicUserSerializer 形态的匿名用户哈希（reply_to_user 等直接返回 JSON 的场景）
    def self.anon_basic_user_json
      {
        id: -1,
        username: ANONYMOUS_NAME,
        name: ANONYMOUS_NAME,
        avatar_template: ::User.avatar_template(ANONYMOUS_NAME, nil),
      }
    end

    # 主题顶楼是否匿名（topic 级掩码判定：created_by / last_poster / participants）
    def self.topic_masked?(topic, scope)
      return false if topic.nil?
      first = topic.first_post
      return false unless first&.custom_fields&.[]("anonymous").present?
      mask_user?(topic.user, scope)
    end

    # 主题内所有匿名帖作者 id
    def self.topic_anon_user_ids(topic)
      ::Post
        .where(topic_id: topic.id)
        .joins(:_custom_fields)
        .where(_custom_fields: { name: "anonymous", value: "true" })
        .pluck(:user_id)
        .uniq
        .to_set
    end

    # ===== 序列化层伪装 =====

    # 帖子流（顶楼 + 回帖）：用户名 / 姓名 / 头像 伪装
    module BasicPostSerializerExtension
      def username
        SchoolEngine::Anonymous.mask?(object, scope) ? SchoolEngine::Anonymous::ANONYMOUS_NAME : super
      end

      def name
        SchoolEngine::Anonymous.mask?(object, scope) ? SchoolEngine::Anonymous::ANONYMOUS_NAME : super
      end

      # 统一"匿"字头像（letter avatar）
      def avatar_template
        if SchoolEngine::Anonymous.mask?(object, scope)
          ::User.avatar_template(SchoolEngine::Anonymous::ANONYMOUS_NAME, nil)
        else
          super
        end
      end
    end

    # 列表页 topic 卡片的 poster 摘要：匿名 poster 的 user_id 指向虚拟匿名用户（-1）
    module TopicPosterSerializerExtension
      def serializable_hash(*args)
        h = super
        if h && school_anonymous_masked?
          h[:user_id] = -1
        end
        h
      end

      private

      def school_anonymous_masked?
        return false unless object.respond_to?(:school_anonymous) && object.school_anonymous
        return false if scope.is_staff?
        if scope.current_user && object.respond_to?(:user)
          return false if scope.current_user.id == object.user&.id
        end
        true
      end
    end

    # 列表项：给每个 poster 打上匿名标记，并伪装最后回复者用户名
    module TopicListItemSerializerExtension
      def posters
        ids = school_anonymous_user_ids
        (super || []).map do |poster|
          poster.school_anonymous = ids.include?(poster.user&.id)
          poster
        end
      end

      def last_poster_username
        p = posters.find { |poster| poster.user.id == object.last_post_user_id }
        return nil unless p
        if p.school_anonymous && !scope.is_staff? && scope.current_user&.id != p.user&.id
          SchoolEngine::Anonymous::ANONYMOUS_NAME
        else
          p.user.username
        end
      end

      private

      def school_anonymous_user_ids
        @school_anonymous_user_ids ||=
          ::Post
            .where(topic_id: object.id)
            .joins(:_custom_fields)
            .where(_custom_fields: { name: "anonymous" })
            .pluck(:user_id)
            .uniq
            .to_set
      end
    end

    # 列表 users 数组：补一个虚拟匿名用户（id=-1），供 poster.user_id=-1 映射
    module CategoryAndTopicListsSerializerExtension
      def users
        users = super
        if school_anonymous_user_ids.any?
          anon = ::User.new(id: -1, username: SchoolEngine::Anonymous::ANONYMOUS_NAME)
          users << anon unless users.any? { |u| u.id == -1 }
        end
        users
      end

      private

      def school_anonymous_user_ids
        @school_anonymous_user_ids ||=
          begin
            ids = []
            (object.topic_list&.topics || []).each do |t|
              ids.concat(
                ::Post
                  .where(topic_id: t.id)
                  .joins(:_custom_fields)
                  .where(_custom_fields: { name: "anonymous" })
                  .pluck(:user_id),
              )
            end
            ids.uniq
          end
      end
    end

    # 主题详情（/t/:id.json 的 details）：顶楼作者 / 最后回复者 / 参与者 掩码
    module TopicViewDetailsSerializerExtension
      def created_by
        topic_masked? ? SchoolEngine::Anonymous.anon_user : super
      end

      def last_poster
        topic_masked? ? SchoolEngine::Anonymous.anon_user : super
      end

      def participants
        ids = SchoolEngine::Anonymous.topic_anon_user_ids(object.topic)
        (super || []).map do |pc|
          u = pc[:user]
          pc[:user] = SchoolEngine::Anonymous.anon_user if u && ids.include?(u.id)
          pc
        end
      end

      private

      def topic_masked?
        SchoolEngine::Anonymous.topic_masked?(object.topic, scope)
      end
    end

    # 帖子流补充字段（BasicPostSerializer 只覆盖 username/name/avatar，
    # PostSerializer 的 display_username 直接读 user.name，会绕过掩码泄露真实姓名）
    module PostSerializerExtension
      def display_username
        SchoolEngine::Anonymous.mask?(object, scope) ? SchoolEngine::Anonymous::ANONYMOUS_NAME : super
      end

      # 被回复者（回复目标帖是匿名帖时掩码，防止跨帖拼接出真实身份）
      def reply_to_user
        target =
          ::Post.find_by(topic_id: object.topic_id, post_number: object.reply_to_post_number)
        if target && SchoolEngine::Anonymous.mask?(target, scope)
          SchoolEngine::Anonymous.anon_basic_user_json
        else
          super
        end
      end

      # 以下特征字段匿名时清空，避免头衔/徽章/用户组间接拼出真实身份
      def user_title
        SchoolEngine::Anonymous.mask?(object, scope) ? nil : super
      end

      def primary_group_name
        SchoolEngine::Anonymous.mask?(object, scope) ? nil : super
      end

      def flair_name
        SchoolEngine::Anonymous.mask?(object, scope) ? nil : super
      end

      def flair_url
        SchoolEngine::Anonymous.mask?(object, scope) ? nil : super
      end

      def flair_group_id
        SchoolEngine::Anonymous.mask?(object, scope) ? nil : super
      end
    end

    # 编辑历史（/posts/:id/revisions）：匿名帖的作者信息与 user_changes 掩码
    module PostRevisionSerializerExtension
      def username
        SchoolEngine::Anonymous.mask?(post, scope) ? "anonymous" : super
      end

      def display_username
        masked? ? SchoolEngine::Anonymous::ANONYMOUS_NAME : super
      end

      def acting_user_name
        masked? ? SchoolEngine::Anonymous::ANONYMOUS_NAME : super
      end

      def avatar_template
        masked? ? ::User.avatar_template(SchoolEngine::Anonymous::ANONYMOUS_NAME, nil) : super
      end

      def user_changes
        result = super
        return result unless masked?
        %w[previous current].each do |side|
          result[side.to_sym][:username] = "anonymous"
          result[side.to_sym][:display_username] = SchoolEngine::Anonymous::ANONYMOUS_NAME
          result[side.to_sym][:avatar_template] =
            ::User.avatar_template(SchoolEngine::Anonymous::ANONYMOUS_NAME, nil)
        end
        result
      end

      private

      def masked?
        SchoolEngine::Anonymous.mask?(post, scope)
      end
    end

    # ===== 全链路 SQL 过滤（匿名帖不出现在公开入口）=====

    ANON_TOPIC_SQL = <<~SQL.freeze
      topics.id NOT IN (
        SELECT t2.id FROM topics t2
        JOIN posts p ON p.topic_id = t2.id AND p.post_number = 1
        JOIN post_custom_fields pcf ON pcf.post_id = p.id
          AND pcf.name = 'anonymous' AND pcf.value = 'true'
      )
    SQL

    ANON_POST_SQL = <<~SQL.freeze
      posts.id NOT IN (
        SELECT post_id FROM post_custom_fields
        WHERE name = 'anonymous' AND value = 'true'
      )
    SQL

    # 用户主页"帖子"tab（topics/created-by/:username）过滤匿名主题
    module TopicQueryExtension
      def list_topics_by(user)
        @options[:filtered_to_user] = user.id
        create_list(:user_topics) do |topics|
          topics.where(user_id: user.id).where(SchoolEngine::Anonymous::ANON_TOPIC_SQL)
        end
      end
    end

    # 用户摘要页（/u/xxx/summary）过滤匿名内容
    module UserSummaryExtension
      def topics
        super.where(SchoolEngine::Anonymous::ANON_TOPIC_SQL)
      end

      def post_query
        super.where(SchoolEngine::Anonymous::ANON_POST_SQL)
      end

      def links
        super.where(SchoolEngine::Anonymous::ANON_POST_SQL)
      end

      # 热门类型：post 数走 post_query（已过滤）；topic 数需单独排除匿名主题
      def top_categories
        post_count_query = post_query.group("topics.category_id")
        top_categories = {}
        Category
          .where(
            id:
              post_count_query
                .order("count(*) DESC")
                .limit(UserSummary::MAX_SUMMARY_RESULTS)
                .pluck("category_id"),
          )
          .pluck(
            :id,
            :name,
            :color,
            :text_color,
            :style_type,
            :icon,
            :emoji,
            :slug,
            :read_restricted,
            :parent_category_id,
          )
          .each do |c|
            top_categories[c[0].to_i] = UserSummary::CategoryWithCounts.new(
              Hash[UserSummary::CategoryWithCounts::KEYS.zip(c)].merge(topic_count: 0, post_count: 0),
            )
          end
        post_count_query
          .where("post_number > 1")
          .where("topics.category_id in (?)", top_categories.keys)
          .pluck("category_id, COUNT(*)")
          .each { |r| top_categories[r[0].to_i].post_count = r[1] }
        Topic
          .listable_topics
          .visible
          .secured(@guardian)
          .where("topics.category_id in (?)", top_categories.keys)
          .where(user: @user)
          .where(SchoolEngine::Anonymous::ANON_TOPIC_SQL)
          .group("topics.category_id")
          .pluck("category_id, COUNT(*)")
          .each { |r| top_categories[r[0].to_i].topic_count = r[1] }
        top_categories.values.sort_by { |r| -(r[:post_count] + r[:topic_count]) }
      end
    end

    # 搜索（@user #category 等）不返回匿名帖
    module SearchExtension
      def posts_query(limit, type_filter: nil, aggregate_search: false)
        super.where(SchoolEngine::Anonymous::ANON_POST_SQL)
      end
    end
  end
end
