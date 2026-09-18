# frozen_string_literal: true

module SchoolEngine
  # 班级圈核心逻辑：自动建圈、入群、小升初选班、毕业标记、通知
  module ClassCircle
    # ---- 注册 / 资料更新 ----

    def self.on_user_created(user)
      if user.custom_fields["status"].blank?
        user.custom_fields["status"] = "在读"
        user.save_custom_fields(true)
      end
      sync_for(user)
      # 欢迎通知（需求 §3.1：自动加入班级圈通知）
      display = Grade.display_class(user)
      notify(user, "欢迎加入！你已自动加入 #{display}")
    end

    def self.on_user_updated(user)
      sync_for(user)
    end

    # 幂等同步：确保用户已加入其当前班级圈（Group + Category 存在）
    # 直接读 DB 里的 custom_fields，避免内存缓存未刷新问题
    def self.sync_for(user, now: Date.current)
      fields = UserCustomField.where(user_id: user.id).pluck(:name, :value).to_h
      gy = fields["graduation_year"].to_i
      return if gy <= 0

      d = gy - Grade.effective_year(now: now)
      cls =
        if d <= 3 && fields["junior_class"].present?
          fields["junior_class"]
        else
          fields["class_name"].to_s
        end
      return if cls.blank?

      prefix = current_prefix(fields, d)
      group =
        Group.find_by(name: Grade.group_name(prefix, gy, cls)) ||
        create_group(prefix, gy, cls, now: now)
      # 修复历史组的可见性（仅成员可见）
      group.update!(
        visibility_level: Group.visibility_levels[:members],
        members_visibility_level: Group.visibility_levels[:members],
      ) if group.visibility_level != Group.visibility_levels[:members]
      GroupUser.find_or_create_by!(group: group, user: user) if group
      category =
        Category.find_by(slug: Grade.circle_key(prefix, gy, cls)) ||
        create_category(prefix, gy, cls, group, now: now)
      # 确保班级圈有对应 Chat 频道（新建/补建）
      ensure_chat_channel_for(category) if category
    end

    # 班级圈前缀：小学阶段(diff>=4)或初一未选班(diff==3 且无 junior_class) => xx；其余 => cz
    def self.current_prefix(fields, d)
      if d.nil? || d >= 4 || (d == 3 && fields["junior_class"].blank?)
        "xx"
      else
        "cz"
      end
    end

    def self.create_group(prefix, gy, cls, now: Date.current)
      display = Grade.display_class({ "graduation_year" => gy.to_s, "class_name" => cls }, now: now)
      Group.create!(
        name: Grade.group_name(prefix, gy, cls),
        full_name: display || Grade.group_name(prefix, gy, cls),
        visibility_level: Group.visibility_levels[:members], # 仅成员可见：非本班学生看不到
        members_visibility_level: Group.visibility_levels[:members],
      )
    end

    def self.create_category(prefix, gy, cls, group, now: Date.current)
      cat = Category.new(
        name: group.full_name || Grade.group_name(prefix, gy, cls),
        slug: Grade.circle_key(prefix, gy, cls),
        color: "0088CC",
        user: Discourse.system_user,
      )
      perms = {
        group => CategoryGroup.permission_types[:full],
        Group[:staff] => CategoryGroup.permission_types[:full],
      }
      if (t = teacher_group)
        perms[t] = CategoryGroup.permission_types[:readonly]
      end
      if (g = graduate_group)
        perms[g] = CategoryGroup.permission_types[:full] # 毕业生可读写（chat/发帖）
      end
      cat.set_permissions(perms)
      cat.save!
      # 班级管理员：本班 Group 作为该分类的 moderation group（本班成员可审核本班内容）
      ::CategoryModerationGroup.find_or_create_by!(category: cat, group: group)
      cat
    end

    # ---- 小升初 ----

    # 是否弹"选择初中班级"模态框（diff==3 且未选且已过8月1日且仍是在读）
    def self.needs_junior_class?(user, now: Date.current)
      return false if user.nil?
      d = Grade.diff(user, now: now)
      d == 3 &&
        user.custom_fields["junior_class"].blank? &&
        user.custom_fields["status"].to_s == "在读" &&
        Grade.after_promotion_date?(now: now)
    end

    def self.select_junior_class!(user, class_name, now: Date.current)
      raise Discourse::InvalidAccess.new("不在小升初阶段") unless needs_junior_class?(user, now: now)
      raise Discourse::InvalidAccess.new("班级名无效") if class_name.blank?

      gy = user.custom_fields["graduation_year"].to_i
      user.custom_fields["junior_class"] = class_name.to_s
      user.save_custom_fields(true)

      # 加入初中班级圈
      sync_for(user, now: now)

      # 小学班级圈显示名固定为"几几届几班"（Group + Category）
      old_cls = user.custom_fields["class_name"].to_s
      fix_class_circle_display(gy, old_cls, prefixes: %w[xx]) if old_cls.present?

      notify(user, "你已升入初中，加入 #{Grade.display_class(user, now: now)} 🎉")
    end

    # "我已离校"（小升初弹窗选项）：小学毕业考去外校初中
    # 状态改"离校"并加入毕业生组（历史班级圈只读），小学班级圈届数固定为中考年-3
    def self.mark_left_school!(user, now: Date.current)
      return false if user.custom_fields["status"].to_s != "在读"

      user.custom_fields["status"] = "离校"
      user.save_custom_fields(true)

      # 加入毕业生组（历史班级圈以毕业生身份只读/访问）
      g = Group.find_by(name: graduate_group)
      g&.users&.<<(user) if g && !user.groups.exists?(id: g.id)

      # 小学班级圈显示名固定为小学毕业届（中考年-3）
      gy = user.custom_fields["graduation_year"].to_i
      cls = user.custom_fields["class_name"].to_s
      fix_class_circle_display(gy, cls, prefixes: %w[xx]) if gy > 0 && cls.present?

      notify(user, "已标记为离校（#{Grade.display_class(user, now: now)}），欢迎以校友身份留在校园社区。")
      true
    end

    # 固定某个班级圈的显示名（Group full_name + Category name）
    # 届数规则：小学圈（xx）= 中考年-3，初中圈（cz）= 中考年（见 Grade.circle_display_name）
    def self.fix_class_circle_display(gy, cls, prefixes: %w[xx cz])
      return if cls.blank?
      norm = Grade.normalize_class_name(cls)
      prefixes.each do |prefix|
        display = Grade.circle_display_name(prefix, gy, cls)
        g = Group.find_by(name: "#{prefix}-#{gy}-#{norm}")
        g&.update!(full_name: display)
        c = Category.find_by(slug: "#{prefix}-class-#{gy}-#{norm}")
        c&.update!(name: display)
      end
    end

    # ---- 毕业标记（每年 8月1日）----

    def self.mark_graduates(now: Date.current)
      return unless now.month == Grade::PROMOTION_MONTH && now.day == Grade::PROMOTION_DAY

      # 8月1日新学年：graduation_year <= 当前年 的视为已毕业（8月1日前 diff 用上学年，不会误伤）
      gy_ids =
        UserCustomField
          .where(name: "graduation_year")
          .where("value ~ '^[0-9]+$' AND value::int <= ?", now.year)
          .pluck(:user_id)
      reading_ids =
        UserCustomField.where(name: "status", value: "在读").pluck(:user_id)
      User.where(id: gy_ids & reading_ids).find_each do |user|
        user.custom_fields["status"] = "毕业生"
        user.save_custom_fields(true)
        fix_circle_display_name(user)
        notify(user, "恭喜毕业！你的账号和所有班级圈子已永久保留 🎓 欢迎以校友身份继续使用校园社区。")

        # 毕业完整时光胶囊：汇总在校期间全部归档内容（含其匿名精选帖），私信发送
        begin
          posts =
            SchoolEngine::Featured.capsule_posts_for(user, include_anonymous: true).to_a
          SchoolEngine::Messages.graduation_capsule!(user, posts) if posts.any?
        rescue => e
          Rails.logger.warn(
            "school-engine: 毕业时光胶囊发送失败 user=#{user.id}: #{e.message}",
          )
        end
      end
    end

    # 毕业时把班级圈显示名固定为"几几届几班"（Group + Category）
    def self.fix_circle_display_name(user)
      gy = user.custom_fields["graduation_year"].to_s
      cls = user.custom_fields["class_name"].to_s
      return if gy.blank? || cls.blank?
      fix_class_circle_display(gy, cls, prefixes: %w[xx cz])
    end

    # 更新所有班级圈显示名（初中圈随 diff 每年变动；已小升初/毕业的小学圈固定为"几几届几班"）
    def self.update_circle_display_names(now: Date.current)
      %w[cz xx].each do |prefix|
        Group.where("name LIKE ?", "#{prefix}-%").find_each do |g|
          m = g.name.match(/\A#{prefix}-(\d{4})-(.+)\z/)
          next unless m
          gy = m[1].to_i
          u = g.users.where.not(id: Discourse.system_user.id).first
          next unless u
          d = Grade.diff(u, now: now).to_i
          jc = u.custom_fields["junior_class"].to_s
          cls = (prefix == "cz" && d <= 3 && jc.present?) ? jc : u.custom_fields["class_name"].to_s
          next if cls.blank?
          if prefix == "xx" && d <= 3 && jc.present?
            # 已小升初：小学圈固定名（届数 = 中考年-3 = 小学毕业年）
            fixed = Grade.circle_display_name("xx", gy, cls)
            g.update!(full_name: fixed)
            c = Category.find_by(slug: "xx-class-#{gy}-#{Grade.normalize_class_name(cls)}")
            c&.update!(name: fixed)
            next
          end
          display =
            Grade.display_class(
              { "graduation_year" => gy.to_s, "class_name" => cls, "junior_class" => jc },
              now: now,
            )
          next if display.blank?
          g.update!(full_name: display)
          c = Category.find_by(slug: g.name.sub(/\A(cz|xx)-/, '\1-class-'))
          c&.update!(name: display)
        end
      end
      ensure_chat_channels!
    end

    # 为单个班级圈分类确保 Chat 频道
    def self.ensure_chat_channel_for(cat)
      return unless defined?(Chat::Channel)
      return if cat.nil?
      channel = Chat::Channel.find_by(chatable: cat, chatable_type: "Category")
      if channel
        channel.update!(name: cat.name) if channel.name != cat.name
      else
        begin
          cat.create_chat_channel(
            name: cat.name,
            slug: cat.slug,
            user_count: 1,
            auto_join_users: true,
          )
        rescue => e
          Rails.logger.warn("[school_engine] chat channel create fail #{cat.slug}: #{e.message}")
        end
      end
    end

    # 历史数据修复：班级圈内移除教师成员（教师不进学生群组）+ 毕业生权限改读写
    def self.fix_circle_permissions!
      t = teacher_group
      g = graduate_group
      full = CategoryGroup.permission_types[:full]
      Group.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").find_each do |grp|
        # 移除教师成员（教师有自己的群组，不进学生班级圈）
        if t
          t.user_ids.each { |uid| GroupUser.where(group: grp, user_id: uid).delete_all }
        end
        # 毕业生：分类权限 full（可发帖/chat）
        if g
          cat = Category.find_by(slug: grp.name.sub(/\A(cz|xx)-/, '\1-class-'))
          cg = CategoryGroup.find_by(category: cat, group: g) if cat
          cg&.update!(permission_type: full)
        end
      end
    end

    # ---- Chat 频道（班级圈在聊天中的呈现，跟随分类权限）----
    # 为所有班级圈分类确保存在对应 Chat 频道，并同步频道名（跟随分类显示名）
    def self.ensure_chat_channels!
      return [] unless defined?(Chat::Channel)
      created = []
      Category.where("slug LIKE 'xx-class-%' OR slug LIKE 'cz-class-%'").find_each do |cat|
        channel = Chat::Channel.find_by(chatable: cat, chatable_type: "Category")
        if channel
          channel.update!(name: cat.name) if channel.name != cat.name
        else
          begin
            cat.create_chat_channel(
              name: cat.name,
              slug: cat.slug,
              user_count: 1,
              auto_join_users: true,
            )
            created << cat.slug
          rescue => e
            Rails.logger.warn("[school_engine] chat channel create fail #{cat.slug}: #{e.message}")
          end
        end
      end
      created
    end

    # ---- 基础结构（MVP：教师/毕业生组 + 四大基础分类）----

    def self.setup_base_structure
      teachers = Group.find_or_create_by!(name: SiteSetting.school_engine_teacher_group)
      graduates = Group.find_or_create_by!(name: SiteSetting.school_engine_graduate_group)

      staff = Group[:staff]
      full = CategoryGroup.permission_types[:full]
      readonly = CategoryGroup.permission_types[:readonly]

      defs = [
        { slug: "chat", name: "校园闲聊", color: "0E76BD", perms: { staff => full } },
        { slug: "share", name: "知识分享", color: "3AB54A", perms: { staff => full } },
        { slug: "confess", name: "表白墙", color: "E45735", perms: { staff => full } },
        { slug: "anonymous-wall", name: "匿名墙", color: "8E44AD", perms: { staff => full } },
        { slug: "announce", name: "校园公告", color: "B22222", perms: { staff => full } },
      ]

      everyone = Group[:everyone]
      defs.each do |d|
        next if Category.find_by(slug: d[:slug])
        perms = d[:perms].dup
        if d[:slug] == "announce"
          perms[everyone] = readonly
          perms[teachers] = full
        else
          perms[everyone] = full
        end
        cat = Category.new(name: d[:name], slug: d[:slug], color: d[:color], user: Discourse.system_user)
        cat.set_permissions(perms)
        cat.save!
      end

      # 表达空间固定标签种子（幂等）
      SchoolEngine::Tags.ensure_tags!

      { teachers: teachers, graduates: graduates }
    end

    # ---- 工具 ----

    def self.teacher_group
      name = SiteSetting.school_engine_teacher_group.to_s
      name.present? ? Group.find_by(name: name) : nil
    end

    def self.graduate_group
      name = SiteSetting.school_engine_graduate_group.to_s
      name.present? ? Group.find_by(name: name) : nil
    end

    def self.notify(user, message)
      return if user.nil?
      Notification.create!(
        user_id: user.id,
        notification_type: Notification.types[:custom],
        data: { title: "校园社区", message: message, display_inline: true }.to_json,
      )
    rescue => e
      Rails.logger.warn("school-engine: 通知失败 user=#{user.id}: #{e.message}")
    end
  end
end
