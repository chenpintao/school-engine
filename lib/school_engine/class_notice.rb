# frozen_string_literal: true

module SchoolEngine
  # 班级通知：staff 在班级圈分类发布主题时可标记"班级通知"
  # 效果：主题置顶；帖子显示发布者真实姓名（无 real_name 时回退昵称）。
  # 仅 staff、首帖、班级圈分类生效；学生侧标记一律忽略。
  module ClassNotice
    CF = "class_notice"

    # 班级圈分类 slug：xx-class-2026-3 / cz-class-2026-3
    CATEGORY_SLUG_REGEX = /\A(?:xx|cz)-class-\d{4}-/

    def self.notice?(post)
      post.custom_fields[CF] == "true"
    end

    # post_created 钩子判定：是否接受本次班级通知标记
    def self.wants_notice?(post, user, opts)
      return false if post.nil?
      return false unless (opts || {})[:school_class_notice].to_s == "true"
      return false unless post.post_number == 1
      return false unless user&.staff?
      post.topic&.category&.slug.to_s.match?(CATEGORY_SLUG_REGEX)
    end

    # 置顶（Discourse 标准 pinned 机制；actor 必须为 staff）
    def self.pin!(post)
      post.topic.update_pinned(true, post.user)
      true
    rescue => e
      Rails.logger.warn("school-engine: 班级通知置顶失败 post=#{post&.id}: #{e.message}")
      false
    end

    # class_notice 帖用于展示的真实姓名；非通知或无 real_name 时返回 nil（调用方回退 super）
    def self.notice_real_name(post)
      return nil unless notice?(post)
      post.user&.custom_fields&.[]("real_name").presence
    end

    # BasicPostSerializer：输出标记位 + 用户名/姓名替换（PostSerializer 继承本类）
    module BasicPostSerializerExtension
      def self.prepended(base)
        base.attributes :school_class_notice
      end

      def school_class_notice
        SchoolEngine::ClassNotice.notice?(object)
      end

      def username
        SchoolEngine::ClassNotice.notice_real_name(object) || super
      end

      def name
        SchoolEngine::ClassNotice.notice_real_name(object) || super
      end
    end

    # PostSerializer 专有字段
    module PostSerializerExtension
      def display_username
        SchoolEngine::ClassNotice.notice_real_name(object) || super
      end
    end
  end
end
