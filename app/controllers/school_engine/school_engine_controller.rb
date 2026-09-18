# frozen_string_literal: true

module SchoolEngine
  # 校园社区业务 API：注册 / 实名 / 资料 / 改密码 / 同学录 / 转班 / 管理员调整 / 小升初
  class SchoolEngineController < ::ApplicationController
    requires_plugin "school-engine"
    wrap_parameters false

    requires_login
    # login_required=true 时未登录 JSON/XHR 会被全局拦截，注册接口必须放行
    skip_before_action :redirect_to_login_if_required, only: [:register_user]

    # staff 专属操作（含联系方式导出）走 guardian；管理类 API 允许"班级管理组"细分授权
    before_action :ensure_staff, only: %i[directory_export feature_post unfeature_post]
    before_action :ensure_school_admin, only: %i[admin_users admin_update_user admin_classes admin_fix_displays]

    CONTACT_KEYS = %w[phone real_email wechat qq other_social].freeze

    # GET /school/junior-class-status.json
    def junior_class_status
      render json: { needs: SchoolEngine::ClassCircle.needs_junior_class?(current_user) }
    end

    # POST /school/select-junior-class.json
    def select_junior_class
      RateLimiter.new(
        current_user,
        "school-junior-class:#{current_user.id}:#{request.remote_ip}",
        10,
        1.hour,
      ).performed!

      params.require(:class_name)
      SchoolEngine::ClassCircle.select_junior_class!(current_user, params[:class_name])
      render json: success_json
    rescue Discourse::InvalidAccess => e
      render json: { errors: [e.message] }, status: :forbidden
    end

    # POST /school/register.json —— 自定义注册向导（邮箱不验证、写学籍字段、自动入群）
    def register_user
      # 防刷：每 IP 每小时 10 次注册尝试（超限由全局 rescue_from 返回 429）
      RateLimiter.new(nil, "school-register:#{request.remote_ip}", 10, 1.hour).performed!

      identity = params[:identity].to_s
      raise Discourse::InvalidParameters.new(:identity) if %w[student teacher].exclude?(identity)

      email = params[:email].to_s.strip.downcase
      username = params[:username].to_s.strip
      password = params[:password].to_s
      raise Discourse::InvalidParameters.new(:email) if email.blank?
      raise Discourse::InvalidParameters.new(:username) if username.blank?
      raise Discourse::InvalidParameters.new(:password) if password.length < SiteSetting.min_password_length

      real_name = params[:real_name].to_s.strip
      fields = { "identity" => identity }

      if identity == "student"
        gy = params[:graduation_year].to_i
        ey = params[:enrollment_year].to_i
        cls = params[:class_name].to_s.strip
        raise Discourse::InvalidParameters.new(:graduation_year) if gy <= 0 || ey <= 0
        raise Discourse::InvalidParameters.new(:graduation_year) unless gy == ey + 9
        raise Discourse::InvalidParameters.new(:class_name) if cls.blank?
        fields.merge!(
          "graduation_year" => gy.to_s,
          "enrollment_year" => ey.to_s,
          "class_name" => cls,
          "status" => "在读",
        )
      else
        teacher_name = params[:teacher_name].to_s.strip
        raise Discourse::InvalidParameters.new(:teacher_name) if teacher_name.blank?
        fields["real_name"] = teacher_name
        fields["real_name_initials"] = SchoolEngine::Pinyin.initials(teacher_name)
        fields["teacher_id_last4"] = params[:teacher_id_last4].to_s.strip
        fields["status"] = "教师"
      end

      # 创建用户（邮箱不验证：直接激活）
      user = User.new(email: email, username: username, password: password)
      user.save!
      user.activate
      user.update!(approved: true)

      # 写学籍 custom_fields
      user.custom_fields.merge!(fields)
      user.save_custom_fields(true)

      # 触发核心生命周期事件：本插件与其它插件的 on(:user_created) 钩子统一响应
      DiscourseEvent.trigger(:user_created, user)

      # 注册即登录
      log_on_user(user)

      render json: { success: true, username: user.username }
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    end

    # POST /school/complete.json —— 学生实名认证（注册后补写 real_name，仅一次）
    def complete_registration
      RateLimiter.new(
        current_user,
        "school-complete:#{current_user.id}:#{request.remote_ip}",
        10,
        1.hour,
      ).performed!

      rn = params[:real_name].to_s.strip
      raise Discourse::InvalidParameters.new(:real_name) if rn.blank?
      if current_user.custom_fields["real_name"].present?
        raise Discourse::InvalidAccess.new("已实名，不可修改")
      end

      current_user.custom_fields["real_name"] = rn
      initials = SchoolEngine::Pinyin.initials(rn)
      if initials.present?
        current_user.custom_fields["real_name_initials"] = initials
      else
        current_user.custom_fields.delete("real_name_initials")
      end
      current_user.save_custom_fields(true)
      DiscourseEvent.trigger(:user_updated, current_user)
      render json: success_json
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    rescue Discourse::InvalidAccess => e
      render json: { errors: [e.message] }, status: :forbidden
    end

    # GET /school/profile.json —— 个人资料页数据（学籍 + 联系方式 + 可见性 + 性别/爱好）
    def profile
      u = current_user
      fields = %w[graduation_year enrollment_year class_name real_name status junior_class]
      render json: {
        username: u.username,
        fields: fields.to_h { |f| [f, u.custom_fields[f]] },
        grade_display: SchoolEngine::Grade.display_class(u),
        gender: u.custom_fields["gender"],
        hobbies: u.custom_fields["hobbies"],
        contact: CONTACT_KEYS.to_h { |k| [k, u.custom_fields["contact_#{k}"]] },
        visibility: CONTACT_KEYS.to_h { |k| [k, self.class.contact_visible?(u.custom_fields, k)] },
      }
    end

    # PUT /school/profile.json —— 更新联系方式/可见性/性别/爱好
    def update_profile
      u = current_user
      contact = params[:contact] || {}
      visibility = params[:visibility] || {}
      contact.each do |k, v|
        next if CONTACT_KEYS.exclude?(k.to_s)
        u.custom_fields["contact_#{k}"] = v.to_s.strip
      end
      visibility.each do |k, v|
        next if CONTACT_KEYS.exclude?(k.to_s)
        u.custom_fields["contact_visibility_#{k}"] = (v == true || v == "true") ? "true" : "false"
      end
      if params.key?(:gender)
        # 传空/保密 → 清除旧值（不再显示性别）
        g = params[:gender].to_s
        u.custom_fields["gender"] = %w[男 女].include?(g) ? g : nil
      end
      if params.key?(:hobbies)
        h = params[:hobbies].to_s.strip
        u.custom_fields["hobbies"] = h.gsub(/[，,、]/, ",").split(",").map(&:strip).reject(&:empty?).uniq.join(",")
      end
      u.save_custom_fields(true)
      DiscourseEvent.trigger(:user_updated, u)
      render json: success_json
    end

    # POST /school/change-password.json —— 直接改密码（原密码 + 新密码，无需邮箱验证）
    def change_password
      # 防爆破：每用户每小时 10 次（超限由全局 rescue_from 返回 429）
      RateLimiter.new(
        current_user,
        "school-change-password:#{current_user.id}:#{request.remote_ip}",
        10,
        1.hour,
      ).performed!

      u = current_user
      current = params[:current_password].to_s
      new_pw = params[:new_password].to_s
      raise Discourse::InvalidParameters.new(:current_password) if current.blank?
      if new_pw.length < SiteSetting.min_password_length
        raise Discourse::InvalidParameters.new(:new_password)
      end
      raise Discourse::InvalidAccess.new("原密码不正确") unless u.confirm_password?(current)

      u.password = new_pw
      u.save!
      render json: success_json
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    rescue Discourse::InvalidAccess => e
      render json: { errors: [e.message] }, status: :forbidden
    end

    # GET /school/directory.json —— 同学录（找人工具）
    # 统一搜索：真实姓名片段 / 拼音首字母 / 班级 / 届 / "2026届3班"组合；也兼容昵称
    # 结果仅返回 昵称 + 届 + 班级，不暴露任何实名/学籍/联系方式字段
    def directory
      query = params[:q].to_s.strip
      limit = [params[:limit].to_i.positive? ? params[:limit].to_i : 50, 100].min

      # 学生身份判定：有入学年份即视为学生（兼容 identity 字段引入前的老数据，教师无该字段）
      scope =
        User.human_users
          .joins(
            "INNER JOIN user_custom_fields school_ey ON school_ey.user_id = users.id AND school_ey.name = 'enrollment_year' AND school_ey.value <> ''",
          )
          .readonly(false)
      scope = scope.where(id: directory_match_scope(query)) if query.present?

      users = scope.order("username_lower ASC").limit(limit).to_a
      render json: { users: users.map { |u| directory_user_json(u) } }
    end

    # GET /school/timeline/:username.json —— 个人时光胶囊（school_capsule 帖；强制排除匿名帖）
    def timeline
      user = User.find_by_username_or_email(params[:username])
      raise Discourse::NotFound if user.nil?

      posts =
        Post
          .joins(:topic)
          .joins(
            "JOIN post_custom_fields school_pcf_capsule ON school_pcf_capsule.post_id = posts.id AND school_pcf_capsule.name = 'school_capsule' AND school_pcf_capsule.value = 'true'",
          )
          .where(user_id: user.id, hidden: false, deleted_at: nil)
          .where(topics: { deleted_at: nil, archived: false })
          .where(
            "posts.id NOT IN (SELECT post_id FROM post_custom_fields WHERE name = 'anonymous' AND value = 'true')",
          )
          .order(posts: { created_at: :desc })
          .limit(100)

      # 教师视角额外排除学生标记"不给老师看"主题（staff 不受限）
      if !current_user&.staff? && SchoolEngine::Visibility.teacher?(current_user)
        posts = posts.where("posts.topic_id NOT IN (#{timeline_hidden_sql})")
      end

      render json: { posts: posts.map { |p| timeline_post_json(p) } }
    rescue Discourse::NotFound
      render json: { errors: ["user not found"] }, status: :not_found
    end

    private

    # 同学录条件解析 → user_id 关系（nil = 无条件）
    def directory_match_scope(query)
      # 组合："2026届3班" / "2026 3班" / "2026-3"
      if (m = query.match(/\A\s*(\d{4})\s*[届级.\-\s]*\s*(\d{1,2})\s*班?\s*\z/))
        return User.where(
          id: cf_scope("graduation_year", m[1]),
        ).where(id: class_scope(m[2]))
      end

      # 纯 4 位数字 → 届（毕业年份）
      return cf_scope("graduation_year", query) if query.match?(/\A\d{4}\z/)

      # "3班" / "3"（1-2 位数字）→ 班级
      if (m = query.match(/\A\s*(\d{1,2})\s*班?\s*\z/))
        return class_scope(m[1])
      end

      # 文本：真实姓名 / 拼音首字母前缀 / 昵称
      like = "%#{query.downcase}%"
      User.where(
        "id IN (:name) OR id IN (:initials) OR username_lower ILIKE :like",
        name: cf_ilike_scope("real_name", like),
        initials: cf_scope("real_name_initials", "#{query.downcase}%", ilike: true),
        like: like,
      )
    end

    # 按 custom field 精确值取 user_id 子查询
    def cf_scope(name, value, ilike: false)
      rel = UserCustomField.where(name: name)
      rel = ilike ? rel.where("value ILIKE ?", value) : rel.where(value: value)
      rel.select(:user_id)
    end

    def cf_ilike_scope(name, value)
      cf_scope(name, value, ilike: true)
    end

    # 班级匹配：class_name / junior_class 去"班"字后等值
    def class_scope(class_digits)
      UserCustomField
        .where(name: %w[class_name junior_class])
        .where("REPLACE(value, '班', '') = ?", class_digits)
        .select(:user_id)
    end

    # 同学录结果序列化：严格白名单，仅 昵称 + 届 + 班级
    def directory_user_json(u)
      f = u.custom_fields
      gy = f["graduation_year"].to_s
      cls = f["junior_class"].presence || f["class_name"].to_s
      cls = cls.strip
      cohort = gy.match?(/\A\d{4}\z/) ? "#{gy}届" : ""
      display = [cohort, cls].reject(&:blank?).join("·")
      { username: u.username, cohort: cohort, class_name: cls, display: display }
    end

    # "不给老师看"主题 id 子查询（供 timeline 教师视角过滤）
    def timeline_hidden_sql
      <<~SQL.squish
        SELECT p.topic_id
        FROM posts p
        JOIN post_custom_fields pcf ON pcf.post_id = p.id
        WHERE p.post_number = 1 AND pcf.name = 'hide_from_staff' AND pcf.value = 'true'
      SQL
    end

    # 时光胶囊帖子序列化（不含匿名帖；匿名帖在查询层已排除）
    def timeline_post_json(post)
      {
        id: post.id,
        url: post.url,
        excerpt: self.class.helpers.strip_tags(post.cooked.to_s).gsub(/\s+/, " ").strip.truncate(200),
        topic_title: post.topic&.title,
        like_count: post.like_count,
        featured: post.custom_fields["school_featured"] == "true",
        featured_at: post.custom_fields["school_featured_at"],
        created_at: post.created_at,
      }
    end

    public

    # POST /school/feature-post.json —— staff 精选表达空间回帖（每日上限 + 系统私信 + 入时光胶囊）
    def feature_post
      post = Post.find(params[:post_id].to_i)
      if SchoolEngine::Featured.feature!(post)
        SchoolEngine::Messages.featured_post_notification!(post)
        render json: success_json
      else
        render json: { errors: [I18n.t("school_engine.feature_already")] }, status: :conflict
      end
    rescue SchoolEngine::Featured::NotEligible
      render json: { errors: [I18n.t("school_engine.feature_not_eligible")] }, status: :unprocessable_entity
    rescue SchoolEngine::Featured::QuotaExceeded
      render json: { errors: [I18n.t("school_engine.feature_quota")] }, status: :forbidden
    end

    # POST /school/unfeature-post.json —— staff 取消精选（释放当日名额，不通知）
    def unfeature_post
      post = Post.find(params[:post_id].to_i)
      SchoolEngine::Featured.unfeature!(post)
      render json: success_json
    end

    # POST /school/leave-school.json —— "我已离校"（小升初弹窗选项，小学毕业考去外校初中）
    def leave_school
      RateLimiter.new(
        current_user,
        "school-leave:#{current_user.id}:#{request.remote_ip}",
        5,
        1.hour,
      ).performed!

      SchoolEngine::ClassCircle.mark_left_school!(current_user)
      render json: success_json
    end

    # GET /school/manage-status.json —— 前端判定是否显示管理界面
    def manage_status
      render json: {
        manage: SchoolEngine::Visibility.school_admin?(current_user),
      }
    end

    # GET /school/admin-users.json —— 学籍用户列表（管理）
    def admin_users
      scope = User.human_users.where(id: UserCustomField.where(name: "identity").select(:user_id))
      scope = filter_by_cf(scope, "status", params[:status])
      scope = filter_by_cf(scope, "identity", params[:identity])
      q = params[:q].to_s.strip
      scope = scope.where("username_lower ILIKE ?", "%#{q.downcase}%") if q.present?
      scope = scope.order("username_lower ASC")

      limit = [[params[:limit].to_i.positive? ? params[:limit].to_i : 50, 200].min, 1].max
      offset = [params[:offset].to_i, 0].max

      render json: {
        total: scope.count,
        users: scope.limit(limit).offset(offset).map { |u| admin_user_json(u) },
      }
    end

    # PUT /school/admin-user.json —— 管理员/班级管理组调整学籍（无视 180 天等限制）
    def admin_update_user
      u = User.find(params[:user_id])

      %w[graduation_year class_name junior_class status real_name gender].each do |key|
        next unless params.key?(key)
        value = params[key].to_s.strip
        if value.empty?
          u.custom_fields.delete(key)
        else
          if key == "graduation_year"
            gy = value.to_i
            raise Discourse::InvalidParameters.new(:graduation_year) if gy <= 0
            value = gy.to_s
          end
          u.custom_fields[key] = value
        end
      end

      # 真实姓名变更时在服务端重算拼音首字母（不采信前端传值）
      if params.key?(:real_name)
        initials = SchoolEngine::Pinyin.initials(params[:real_name].to_s.strip)
        if initials.present?
          u.custom_fields["real_name_initials"] = initials
        else
          u.custom_fields.delete("real_name_initials")
        end
      end

      u.custom_fields.delete("last_class_change") if params[:reset_cooldown] == "true"

      u.save_custom_fields(true)
      DiscourseEvent.trigger(:user_updated, u)
      render json: success_json.merge(display_class: SchoolEngine::Grade.display_class(u))
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    end

    # GET /school/admin-classes.json —— 班级圈列表（Group + Category + 人数）
    def admin_classes
      groups =
        Group
          .where("name LIKE 'xx-%' OR name LIKE 'cz-%'")
          .order("name ASC")
          .map do |g|
            prefix, gy, cls = parse_circle_group_name(g.name)
            cat = Category.find_by(slug: Grade.circle_key(prefix, gy, cls)) if prefix
            {
              group_name: g.name,
              full_name: g.full_name,
              user_count: g.user_count,
              prefix: prefix,
              graduation_year: gy,
              class_name: cls,
              category_slug: cat&.slug,
              category_name: cat&.name,
              chat: cat && defined?(::Chat::Channel) ? ::Chat::Channel.where(chatable: cat).exists? : false,
            }
          end
      render json: { classes: groups }
    end

    # POST /school/admin-fix-displays.json —— 全量修正班级圈显示名（届数规则变更后可用）
    def admin_fix_displays
      SchoolEngine::ClassCircle.update_circle_display_names
      SchoolEngine::Tags.ensure_tags!
      backfill_name_initials!
      render json: success_json
    end

    # 为老用户回填拼音首字母（历史数据 real_name 存在但 real_name_initials 缺失）
    def backfill_name_initials!
      User
        .human_users
        .where(
          id:
            UserCustomField
              .where(name: "real_name")
              .where.not(value: [nil, ""])
              .select(:user_id)
        )
        .find_each do |u|
          next if u.custom_fields["real_name_initials"].present?
          initials = SchoolEngine::Pinyin.initials(u.custom_fields["real_name"].to_s)
          next if initials.blank?
          u.custom_fields["real_name_initials"] = initials
          u.save_custom_fields(true)
        end
    end

    # 联系方式是否公开（boolean custom field 存 "f"/false）
    def self.contact_visible?(fields, key)
      v = fields["contact_visibility_#{key}"]
      v.nil? || !%w[false f 0].include?(v.to_s)
    end

    # GET /school/directory.csv —— 同学录导出（仅管理员，含全部字段；ensure_staff 已校验）
    def directory_export
      level = params[:level].to_s
      username = params[:username].to_s.strip
      hobby = params[:hobby].to_s.strip
      query = params[:q].to_s.strip

      q = User.human_users
      q = q.where(id: UserCustomField.where(name: "enrollment_year").select(:user_id))
      # 与同学录搜索框一致的统一查询（姓名/首字母/班级/届/组合）
      q = q.where(id: directory_match_scope(query)) if query.present?
      if level.present?
        c = level.to_i
        ey_ids =
          UserCustomField
            .where(name: "enrollment_year", value: [c.to_s, (c - 6).to_s])
            .select(:user_id)
        q = q.where(id: ey_ids)
      end
      if username.present?
        q = q.where("username_lower ILIKE ?", "%#{username.downcase}%")
      end
      if hobby.present?
        q = q.where(
          "id IN (SELECT user_id FROM user_custom_fields WHERE name = 'hobbies' AND value ILIKE ?)",
          "%#{hobby}%",
        )
      end

      users = q.to_a
      require "csv"
      csv =
        CSV.generate do |out|
          out << %w[username 真实姓名 毕业年份 入学年份 班级 初中班级 状态 手机号 邮箱 微信 QQ 其他]
          users.each do |u|
            f = u.custom_fields
            out << [
              u.username,
              f["real_name"],
              f["graduation_year"],
              f["enrollment_year"],
              f["class_name"],
              f["junior_class"],
              f["status"],
              f["contact_phone"],
              f["contact_real_email"],
              f["contact_wechat"],
              f["contact_qq"],
              f["contact_other_social"],
            ]
          end
        end
      send_data csv, filename: "同学录-#{Time.current.strftime("%Y%m%d")}.csv", type: "text/csv; charset=utf-8"
    end

    # POST /school/transfer-class.json —— 假期自助转班（180 天限制）
    def transfer_class
      u = current_user
      new_cls = params[:class_name].to_s.strip
      raise Discourse::InvalidParameters.new(:class_name) if new_cls.blank?
      if %w[1班 2班 3班 4班 5班 6班].exclude?(new_cls)
        raise Discourse::InvalidParameters.new(:class_name)
      end

      last = u.custom_fields["last_class_change"].to_i
      if last > 0 && (Time.current.to_i - last) < 180 * 24 * 3600
        next_ok = Time.at(last + 180 * 24 * 3600).strftime("%Y-%m-%d")
        raise Discourse::InvalidAccess.new("距上次转班不足 180 天，下次可修改：#{next_ok}")
      end

      current_cls = u.custom_fields["junior_class"].presence || u.custom_fields["class_name"].to_s
      raise Discourse::InvalidParameters.new(:class_name) if current_cls == new_cls

      if u.custom_fields["junior_class"].present?
        u.custom_fields["junior_class"] = new_cls
      else
        u.custom_fields["class_name"] = new_cls
      end
      u.custom_fields["last_class_change"] = Time.current.to_i.to_s
      u.save_custom_fields(true)
      # 班级圈同步走 user_updated 事件（plugin.rb 钩子幂等执行 sync_for）
      DiscourseEvent.trigger(:user_updated, u)
      SchoolEngine::ClassCircle.notify(
        u,
        "你已加入新班级圈子 #{SchoolEngine::Grade.display_class(u)}，旧班级仍可访问",
      )
      render json: success_json
    rescue Discourse::InvalidParameters => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    rescue Discourse::InvalidAccess => e
      render json: { errors: [e.message] }, status: :forbidden
    end

    private

    # DC 权限体系：staff 校验统一入口（guardian 全局 rescue → 403）
    def ensure_staff
      guardian.ensure_staff!
    end

    # 细分授权：staff 或"班级管理组"成员均可管理学籍（全局 rescue → 403）
    def ensure_school_admin
      raise Discourse::InvalidAccess.new unless SchoolEngine::Visibility.school_admin?(current_user)
    end

    # 管理列表行序列化（学籍全量字段 + 组 + 年级显示名）
    def admin_user_json(u)
      f = u.custom_fields
      {
        id: u.id,
        username: u.username,
        avatar_template: u.avatar_template,
        identity: f["identity"],
        real_name: f["real_name"],
        graduation_year: f["graduation_year"],
        enrollment_year: f["enrollment_year"],
        class_name: f["class_name"],
        junior_class: f["junior_class"],
        status: f["status"],
        gender: f["gender"],
        display_class: SchoolEngine::Grade.display_class(u),
        groups: u.groups.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").pluck(:name),
      }
    end

    # 按自定义字段值筛选用户（"all"/空 = 不过滤）
    def filter_by_cf(scope, name, value)
      v = value.to_s.strip
      return scope if v.empty? || v == "all"
      scope.where(id: UserCustomField.where(name: name, value: v).select(:user_id))
    end

    # 解析班级圈组名：{xx|cz}-{gy}-{cls} → [prefix, gy, cls]
    def parse_circle_group_name(name)
      m = name.match(/\A(xx|cz)-(\d{4})-(.+)\z/)
      m ? [m[1], m[2].to_i, m[3]] : [nil, nil, nil]
    end
  end
end
