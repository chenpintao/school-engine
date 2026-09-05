# frozen_string_literal: true

module SchoolEngine
  # 可见性控制（"学生发帖可选择不给老师看"）
  #
  # 权限模型：
  #  - 教师组（SiteSetting.school_engine_teacher_group）：可读所有正常帖；
  #    但学生标记 hide_from_staff 的主题对教师 404（列表同样过滤）
  #  - 管理员（Discourse staff）：无视一切限制（可溯源、可管理）
  #  - 班级管理组（SiteSetting.school_engine_class_admin_group）：
  #    可使用校园管理 API（非 staff 的细分授权）
  module Visibility
    # 顶楼带 hide_from_staff 标记的主题（对教师隐藏）
    HIDDEN_TOPIC_SQL = <<~SQL.freeze
      topics.id NOT IN (
        SELECT t2.id FROM topics t2
        JOIN posts p ON p.topic_id = t2.id AND p.post_number = 1
        JOIN post_custom_fields pcf ON pcf.post_id = p.id
          AND pcf.name = 'hide_from_staff' AND pcf.value = 'true'
      )
    SQL

    # 教师判定（排除 staff：admin 拥有全量权限，不受教师限制影响）
    def self.teacher?(user)
      return false if user.nil? || user.staff?
      in_group?(user, SiteSetting.school_engine_teacher_group)
    end

    # 细分管理组判定（用于管理 API 的非 staff 授权）
    def self.school_admin?(user)
      return false if user.nil?
      return true if user.staff?
      in_group?(user, SiteSetting.school_engine_class_admin_group)
    end

    def self.in_group?(user, group_name)
      gname = group_name.to_s.strip
      return false if gname.empty?
      group = ::Group.find_by(name: gname)
      return false if group.nil?
      group.users.where(id: user.id).exists?
    end

    # 教师是否被禁止查看该主题（作者本人与管理员不受限）
    def self.blocked_for_teacher?(topic, user)
      return false if topic.nil?
      return false unless teacher?(user)
      return false if user.id == topic.user_id
      first_post_cf = topic.first_post&.custom_fields || {}
      first_post_cf["hide_from_staff"].present?
    end

    # 从路由 params 定位主题（/t/:id、/t/:slug/:id、/t/:topic_id/posts 三种形态）
    def self.find_topic(params)
      id = params[:topic_id].presence || params[:id].presence
      return nil if id.blank?
      id.to_s.match?(/\A\d+\z/) ? ::Topic.find_by(id: id) : ::Topic.find_by(slug: id)
    end

    # ===== 教师访问拦截（prepend + super，热重载安全）=====

    # 主题详情 / 帖子流：教师访问 hide_from_staff 主题 → 404
    module TopicsControllerExtension
      %i[show posts feed].each do |action|
        define_method(action) do |*args, &block|
          topic = ::SchoolEngine::Visibility.find_topic(params)
          if ::SchoolEngine::Visibility.blocked_for_teacher?(topic, current_user)
            raise ::Discourse::NotFound
          end
          super(*args, &block)
        end
      end
    end

    # 单帖 JSON（/posts/:id.json）：所属主题对教师隐藏 → 404
    module PostsControllerExtension
      def show(*args, &block)
        post = ::Post.find_by(id: params[:id])
        topic = post&.topic
        if ::SchoolEngine::Visibility.blocked_for_teacher?(topic, current_user)
          raise ::Discourse::NotFound
        end
        super(*args, &block)
      end
    end

    # 主题列表：教师视角过滤掉 hide_from_staff 主题（其他用户正常可见）
    module TopicQueryExtension
      def default_results(*args, &block)
        result = super(*args, &block)
        if ::SchoolEngine::Visibility.teacher?(@user)
          result = result.where(::SchoolEngine::Visibility::HIDDEN_TOPIC_SQL)
        end
        result
      end
    end
  end
end
