# frozen_string_literal: true

module SchoolEngine
  # 年级计算引擎（6+3 学制）
  #
  # 学年节点：每年 8月1日 升年级（8月1日前按上一学年计算）
  # effective_year = 已过8月1日 ? 当前年 : 当前年-1
  # diff = graduation_year - effective_year
  #  9..4  => 小一..小六（小学阶段）
  #  3..0  => 初一..初三（初中阶段，diff=0 为毕业年，8月1日后视为已毕业）
  #  <0    => 校友
  module Grade
    GRADE_MAP = {
      9 => "小一",
      8 => "小二",
      7 => "小三",
      6 => "小四",
      5 => "小五",
      4 => "小六",
      3 => "初一",
      2 => "初二",
      1 => "初三",
      0 => "初三",
    }.freeze

    # 学年"升年级"节点：8月1日（8月1日起按新学年计算）
    PROMOTION_MONTH = 8
    PROMOTION_DAY  = 1

    # 当前学籍年（8月1日前 = 上一学年）
    def self.effective_year(now: Date.current)
      after_promotion_date?(now: now) ? now.year : now.year - 1
    end

    # 计算 diff；无有效毕业年份返回 nil
    def self.diff(user_or_fields, now: Date.current)
      gy = fetch(user_or_fields, "graduation_year").to_i
      return nil if gy <= 0
      gy - effective_year(now: now)
    end

    # 年级名（"小一".."初三" / "校友" / "未知"）
    def self.grade_name(diff)
      return "未知" if diff.nil? || diff >= 10
      return "校友" if diff < 0
      GRADE_MAP[diff] || "未知"
    end

    # 是否已毕业（8月1日 后 diff<=0；8月1日 前不可能为 0）
    def self.graduated?(user_or_fields, now: Date.current)
      d = diff(user_or_fields, now: now)
      d ? d <= 0 : false
    end

    # 班级圈显示名："初二·3班"；毕业生："2024届3班"；选班后的初中生显示初中班级
    # 离校生（小学毕业考去外校初中）："20xx届x班"（届数 = 中考年-3 = 小学毕业年）
    def self.display_class(user_or_fields, now: Date.current)
      d = diff(user_or_fields, now: now)
      cls = fetch(user_or_fields, "class_name").to_s.strip
      jc = fetch(user_or_fields, "junior_class").to_s.strip
      gy = fetch(user_or_fields, "graduation_year").to_i

      if fetch(user_or_fields, "status") == "离校"
        return nil unless gy > 0 && cls.present?
        return circle_display_name("xx", gy, cls)
      end

      cls = jc if d && d <= 3 && jc.present?
      return nil if d.nil? || cls.empty?
      if graduated?(user_or_fields, now: now)
        "#{fetch(user_or_fields, "graduation_year")}届#{cls}"
      else
        "#{grade_name(d)}·#{cls}"
      end
    end

    # 班级圈"届"显示名：小学圈（xx）的届数 = 中考年-3（小学毕业年）；初中圈（cz）= 中考年
    def self.circle_display_name(prefix, gy, cls)
      return "#{gy - 3}届#{cls}" if prefix == "xx"
      "#{gy}届#{cls}"
    end

    # 班级圈 Category slug：{prefix}-class-{gy}-{cls}（如 cz-class-2027-3）
    def self.circle_key(prefix, gy, cls)
      "#{prefix}-class-#{gy}-#{normalize_class_name(cls)}"
    end

    # Group 名（Discourse 限制 ≤20 字符、仅小写字母数字连字符）：{prefix}-{gy}-{cls}
    def self.group_name(prefix, gy, cls)
      "#{prefix}-#{gy}-#{normalize_class_name(cls)}"
    end

    # 班级圈前缀（由 ClassCircle 按用户状态决定）：小学阶段或未选班的初一 => xx
    def self.prefix_for(diff)
      diff >= 4 ? "xx" : "cz"
    end

    # 班级 slug 规范化："3班" => "3"；去空格、去"班"字、仅保留字母数字
    def self.normalize_class_name(cls)
      cls.to_s.strip.sub(/班\z/, "").gsub(/[^0-9A-Za-z\u4e00-\u9fa5]/, "").presence || "unknown"
    end

    # 是否已过本年升学节点（>= 8月1日）
    def self.after_promotion_date?(now: Date.current)
      (now.month > PROMOTION_MONTH) || (now.month == PROMOTION_MONTH && now.day >= PROMOTION_DAY)
    end

    def self.fetch(user_or_fields, key)
      if user_or_fields.respond_to?(:custom_fields)
        user_or_fields.custom_fields[key].presence
      else
        user_or_fields[key].presence
      end
    end
  end
end
