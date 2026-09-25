# frozen_string_literal: true

module SchoolEngine
  # 班级圈核心逻辑：自动建圈、入群、小升初选班、毕业标记、通知
  module ClassCircle
    # ---- 注册 / 资料更新 ----

    def self.on_user_created(user)
      if user.custom_fields["status"].blank?
        user.custom_fields["status"] =
          user.custom_fields["identity"] == "teacher" ? "教师" : "在读"
        user.save_custom_fields(true)
      end
      sync_for(user)
      # 欢迎通知（需求 §3.1：自动加入班级圈通知；教师无班级圈，不发空通知）
      display = Grade.display_class(user)
      notify(user, "欢迎加入！你已自动加入 #{display}") if display.present?
    end

    def self.on_user_updated(user)
      sync_for(user)
    end

    # 幂等同步：确保用户已加入其当前班级圈（Group + Category 存在）
    # 直接读 DB 里的 custom_fields，避免内存缓存未刷新问题。
    # 返回结果哈希（joined/grad_joined/teacher_joined 供一键重算统计）：
    #   { skipped: true }                                      # 无需同步
    #   { teacher_joined: true }                               # 教师入教师组
    #   { joined:, grad_joined:, group:, category: }           # 学生班级圈
    def self.sync_for(user, now: Date.current)
      fields = UserCustomField.where(user_id: user.id).pluck(:name, :value).to_h

      # 教师 → 自动进教师组（教师不进学生班级圈）
      if fields["identity"] == "teacher" || fields["status"] == "教师"
        t = teacher_group
        if t && !GroupUser.exists?(group_id: t.id, user_id: user.id)
          GroupUser.find_or_create_by!(group: t, user: user)
          return { teacher_joined: true }
        end
        return { skipped: true }
      end

      gy = fields["graduation_year"].to_i
      return { skipped: true } if gy <= 0
      # staff 已有全部班级圈 full 权限，无需入学生群组（避免为测试账号建空圈）
      return { skipped: true } if user.staff?

      d = gy - Grade.effective_year(now: now)
      cls =
        if d <= 3 && fields["junior_class"].present?
          fields["junior_class"]
        else
          fields["class_name"].to_s
        end
      return { skipped: true } if cls.blank?

      prefix = current_prefix(fields, d)
      group =
        Group.find_by(name: Grade.group_name(prefix, gy, cls)) ||
        create_group(prefix, gy, cls, now: now)
      # 修复历史组的可见性（仅成员可见）
      group.update!(
        visibility_level: Group.visibility_levels[:members],
        members_visibility_level: Group.visibility_levels[:members],
      ) if group.visibility_level != Group.visibility_levels[:members]

      joined = !GroupUser.exists?(group_id: group.id, user_id: user.id)
      GroupUser.find_or_create_by!(group: group, user: user) if group

      category =
        Category.find_by(slug: Grade.circle_key(prefix, gy, cls)) ||
        create_category(prefix, gy, cls, group, now: now)
      # 板块权限自愈：入群即拥有对应板块（Group 行缺失/被改也能修复）
      ensure_category_permissions(category, group) if category
      # 确保班级圈有对应 Chat 频道（新建/补建）
      ensure_chat_channel_for(category) if category

      # 毕业生 / 离校 → 毕业生组：全部班级圈板块 full（可读可发帖，非只读）
      grad_joined = false
      if %w[毕业生 离校].include?(fields["status"]) && (g = graduate_group)
        unless GroupUser.exists?(group_id: g.id, user_id: user.id)
          GroupUser.find_or_create_by!(group: g, user: user)
          grad_joined = true
        end
      end

      { joined: joined, grad_joined: grad_joined, group: group, category: category }
    end

    # 板块权限自愈（幂等）：本班群组 full、staff full、教师 readonly、毕业生 full。
    # 行已存在且权限正确时不写库；其余自定义授权组合并保留。
    def self.ensure_category_permissions(cat, class_group)
      return if cat.nil? || class_group.nil?
      full = CategoryGroup.permission_types[:full]
      readonly = CategoryGroup.permission_types[:readonly]
      desired = { class_group.id => full, Group[:staff].id => full }
      desired[teacher_group.id] = readonly if teacher_group
      desired[graduate_group.id] = full if graduate_group

      existing = CategoryGroup.where(category_id: cat.id).pluck(:group_id, :permission_type).to_h
      return if desired.all? { |gid, type| existing[gid] == type }

      cat.set_permissions(existing.merge(desired))
      cat.save!
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
    # 状态改"离校"并加入毕业生组（历史班级圈可读可发帖），小学班级圈届数固定为中考年-3
    def self.mark_left_school!(user, now: Date.current)
      return false if user.custom_fields["status"].to_s != "在读"

      user.custom_fields["status"] = "离校"
      user.save_custom_fields(true)

      # 加入毕业生组（以毕业生身份访问班级圈板块：full 权限，可读可发帖）
      g = Group.find_by(name: graduate_group)
      if g && !GroupUser.exists?(group_id: g.id, user_id: user.id)
        GroupUser.find_or_create_by!(group: g, user: user)
      end

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
        # 加入毕业生组：班级圈板块保留 full 权限（毕业后可读可发帖，非只读）
        if (g = graduate_group)
          GroupUser.find_or_create_by!(group: g, user: user) unless GroupUser.exists?(group_id: g.id, user_id: user.id)
        end
        sync_for(user, now: now)
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

    # ---- 一键重算（管理页按钮）：所有人的状态 + 群组成员 + 板块权限 + Chat 频道 ----
    # 幂等：可反复执行。返回统计哈希供前端展示。
    def self.recalculate_all!(now: Date.current)
      stats = {
        users: 0,
        students: 0,
        teachers: 0,
        joined_groups: 0,
        status_changed: 0,
        circles: 0,
        channels_created: 0,
        errors: [],
      }

      # 基础组兜底
      Group.find_or_create_by!(name: SiteSetting.school_engine_teacher_group)
      Group.find_or_create_by!(name: SiteSetting.school_engine_graduate_group)

      User.human_users.find_each do |user|
        fields = UserCustomField.where(user_id: user.id).pluck(:name, :value).to_h
        # 仅处理校园账号（有学籍字段者）
        next if fields["identity"].blank? && fields["graduation_year"].blank? &&
                  fields["status"].blank?
        stats[:users] += 1

        begin
          if fields["identity"] == "teacher" || fields["status"] == "教师"
            stats[:teachers] += 1
            # 教师状态归一化（历史数据可能残留"在读"等）
            if fields["identity"] == "teacher" && fields["status"] != "教师"
              user.custom_fields["status"] = "教师"
              user.save_custom_fields(true)
              stats[:status_changed] += 1
            end
            result = sync_for(user, now: now)
            stats[:joined_groups] += 1 if result[:teacher_joined]
            next
          end

          gy = fields["graduation_year"].to_i
          next if gy <= 0
          stats[:students] += 1

          # 状态重算（只升不降）：空白 → 在读；在读且已到毕业年 → 毕业生
          status = fields["status"].to_s
          new_status =
            if status.empty?
              "在读"
            elsif status == "在读" && Grade.graduated?(fields, now: now)
              "毕业生"
            end
          if new_status
            user.custom_fields["status"] = new_status
            user.save_custom_fields(true)
            fields["status"] = new_status
            stats[:status_changed] += 1
          end

          result = sync_for(user, now: now)
          stats[:joined_groups] += 1 if result[:joined]
          stats[:joined_groups] += 1 if result[:grad_joined]
        rescue => e
          stats[:errors] << "#{user.username}: #{e.message}"
        end
      end

      # 权限/显示名/Chat 频道全量修复
      fix_circle_permissions!
      update_circle_display_names(now: now)
      created = ensure_chat_channels!
      stats[:channels_created] = created.length
      stats[:circles] = Group.where("name LIKE 'xx-%' OR name LIKE 'cz-%'").count

      # 立即按新板块权限补一轮 Chat 频道自动加入（定时任务每小时也会跑）
      if defined?(::Chat::AutoJoinChannels)
        begin
          ::Chat::AutoJoinChannels.call(params: {})
        rescue => e
          Rails.logger.warn("school-engine: 重算后 Chat 自动加入失败: #{e.message}")
        end
      end

      stats
    end

    # ---- 基础结构 ----
    # 只确保学制引擎运转所需的两个群组（名称可在站点设置中修改，留空则跳过）。
    # 不创建任何板块/标签：板块由管理员自行规划，匿名/精选等行为通过
    # 站点设置 school_engine_category_rules 绑定到任意分类。
    # 需要一键创建默认板块模板时，请显式执行 seed_default_categories!。
    def self.setup_base_structure
      result = { teachers: nil, graduates: nil }

      teacher_name = SiteSetting.school_engine_teacher_group.to_s.strip
      if teacher_name.present?
        result[:teachers] = Group.find_or_create_by!(name: teacher_name)
      end

      graduate_name = SiteSetting.school_engine_graduate_group.to_s.strip
      if graduate_name.present?
        result[:graduates] = Group.find_or_create_by!(name: graduate_name)
      end

      result
    end

    # 可选的默认板块模板（幂等）。仅在管理员显式调用（rake school_engine:seed_categories）时执行：
    # 校园闲聊 / 知识分享 / 表白墙(可选匿名) / 匿名墙(强制匿名) / 校园公告
    # 创建后随时可在后台改名、调整权限或删除；匿名行为以 school_engine_category_rules 设置为准。
    def self.seed_default_categories!
      teachers = teacher_group
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
      created = []
      defs.each do |d|
        next if Category.find_by(slug: d[:slug])
        perms = d[:perms].dup
        if d[:slug] == "announce"
          perms[everyone] = readonly
          perms[teachers] = full if teachers
        else
          perms[everyone] = full
        end
        cat = Category.new(name: d[:name], slug: d[:slug], color: d[:color], user: Discourse.system_user)
        cat.set_permissions(perms)
        cat.save!
        created << d[:slug]
      end

      created
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
