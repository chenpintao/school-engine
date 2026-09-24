# frozen_string_literal: true

module SchoolEngine
  # 每日心情签到：用单条 user custom field（mood_checkins）存 JSON，
  # 结构 { "2026-09-24" => 4 }，无需额外数据表。读写全部经本模块，
  # 前端只允许通过 controller 接口写入（不可自助伪造其它日期）。
  module Mood
    CF_NAME = "mood_checkins"
    RANGE = (1..5).freeze

    def self.load_map(user)
      raw = user.custom_fields[CF_NAME].to_s
      return {} if raw.blank?

      data = JSON.parse(raw)
      data.is_a?(Hash) ? data.select { |_, v| RANGE.include?(v.to_i) } : {}
    rescue JSON::ParserError
      {}
    end

    # 今日签到/改签（同一天允许更改心情）
    def self.checkin!(user, mood)
      mood = mood.to_i
      raise Discourse::InvalidParameters.new(:mood) unless RANGE.include?(mood)

      map = load_map(user)
      map[Time.zone.today.iso8601] = mood
      user.custom_fields[CF_NAME] = JSON.generate(map)
      user.save_custom_fields(true)
      mood
    end

    def self.today(user)
      load_map(user)[Time.zone.today.iso8601]&.to_i
    end

    # 近 days 天（含今天）的签到，返回按日期升序的 { "2026-09-24" => 4 }
    def self.recent_map(user, days)
      since = Time.zone.today - (days - 1)
      load_map(user)
        .select { |date, _| Date.iso8601(date) >= since }
        .sort
        .to_h
    rescue ArgumentError
      {}
    end
  end
end
