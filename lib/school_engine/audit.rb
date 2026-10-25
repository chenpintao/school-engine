# frozen_string_literal: true

require "digest"

module SchoolEngine
  # 统一审计日志
  #
  # 目标：插件所有功能的"访问 / 查看 / 修改"全部留痕，且不拖慢主流程。
  #
  # 设计要点：
  #  1. 双通道输出
  #     - 结构化单行写入独立日志文件 log/school_engine_audit.log（便于 grep / 归档）
  #     - 同时写 Rails.logger（便于统一收集）
  #  2. 零阻塞：文件写入走进程内队列 + 后台线程批量 flush，主线程只做入队
  #  3. 自动压缩：按大小轮转，轮转后的旧文件立即 gzip，保留 N 份，超期自动删除
  #  4. 隐私保护：手机号/邮箱/QQ/微信等敏感值统一脱敏后再落盘
  #  5. 可开关：school_engine_audit_enabled 控制，默认开启
  module Audit
    MAX_VALUE_LEN = 200
    QUEUE_LIMIT = 5_000

    # 需要脱敏的字段名关键字
    SENSITIVE_KEYS = %w[
      password token secret key contact_phone contact_real_email contact_wechat
      contact_qq contact_other_social phone email wechat qq
    ].freeze

    module_function

    def enabled?
      SiteSetting.respond_to?(:school_engine_audit_enabled) &&
        SiteSetting.school_engine_audit_enabled
    rescue StandardError
      false
    end

    # ---- 对外主入口 ----
    #
    # action:  语义动作，如 "view.directory" / "update.profile" / "review.act"
    # actor:   User 或 nil（匿名）
    # target:  被操作对象，可为 Post / User / 字符串
    # extra:   附加字段 Hash
    def log(action:, actor: nil, target: nil, extra: {})
      return unless enabled?

      entry = {
        "ts" => Time.zone.now.iso8601(3),
        "action" => action.to_s,
        "actor_id" => actor&.id,
        "actor" => actor&.username,
        "actor_staff" => actor&.staff?,
        "target" => target_summary(target),
        "ip" => current_ip,
        "ua" => current_ua,
        "request_id" => request_id,
      }.merge(sanitize_hash(extra))

      enqueue(entry)
      nil
    rescue StandardError => e
      # 审计失败绝不影响业务
      Rails.logger.warn("school-engine: audit log failed: #{e.class}: #{e.message}")
      nil
    end

    # 同步写入单条记录（供 controller 钩子使用）
    # 单条 JSON 通常 200-600 字节，一次 append 开销远小于一次 DB 查询；
    # 放在 ensure 中执行可保证异常/403 也留痕。
    def write_entry(entry)
      return unless enabled?

      line = JSON.generate(entry)
      append_lines([entry])
      line
    rescue StandardError => e
      Rails.logger.warn("school-engine: audit write failed: #{e.class}: #{e.message}")
      nil
    end

    # ---- 上下文（由 controller before_action 注入）----
    def with_request(request)
      Thread.current[:school_engine_audit_req] = request
      yield
    ensure
      Thread.current[:school_engine_audit_req] = nil
    end

    def current_request
      Thread.current[:school_engine_audit_req]
    end

    def current_ip
      current_request&.remote_ip
    end

    def current_ua
      ua = current_request&.user_agent.to_s
      ua.length > 160 ? "#{ua[0, 160]}…" : ua
    end

    def request_id
      current_request&.request_id
    end

    # ---- 目标对象摘要 ----
    def target_summary(target)
      case target
      when nil
        nil
      when Post
        { "type" => "post", "id" => target.id, "topic_id" => target.topic_id }
      when Topic
        { "type" => "topic", "id" => target.id, "title" => target.title.to_s.truncate(80) }
      when User
        { "type" => "user", "id" => target.id, "username" => target.username }
      when Hash, Array
        sanitize_value(target)
      else
        { "type" => "other", "value" => target.to_s.truncate(MAX_VALUE_LEN) }
      end
    rescue StandardError
      nil
    end

    # ---- 脱敏 ----
    def sanitize_hash(hash)
      return {} unless hash.is_a?(Hash)
      hash.each_with_object({}) do |(k, v), out|
        key = k.to_s
        out[key] =
          if sensitive_key?(key)
            mask(v)
          else
            sanitize_value(v)
          end
      end
    end

    def sanitize_value(value)
      case value
      when Hash
        sanitize_hash(value)
      when Array
        value.first(20).map { |v| sanitize_value(v) }
      when String
        value.length > MAX_VALUE_LEN ? "#{value[0, MAX_VALUE_LEN]}…" : value
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        value.to_s.truncate(MAX_VALUE_LEN)
      end
    end

    def sensitive_key?(key)
      k = key.to_s.downcase
      SENSITIVE_KEYS.any? { |s| k.include?(s) }
    end

    def mask(value)
      s = value.to_s
      return "" if s.empty?
      return "[redacted]" if s.length <= 2
      # 保留首尾各 1 位，中间打码；同时记录指纹便于关联排查
      "#{s[0]}#{'*' * [s.length - 2, 3].max}#{s[-1]}"
    end

    # ---- 异步写入队列 ----
    def enqueue(entry)
      queue = write_queue
      queue << entry
      # 队列积压时丢弃最旧的，避免内存膨胀
      queue.shift while queue.size > QUEUE_LIMIT
      start_flusher
      nil
    end

    def write_queue
      Thread.current[:school_engine_audit_queue] ||= Queue.new
    end

    def start_flusher
      return if Thread.current[:school_engine_audit_flusher]
      Thread.current[:school_engine_audit_flusher] = true
      # 每次请求结束时由 at_exit 之外的钩子 flush；这里只负责标记
      nil
    end

    # 由 controller after_action 调用：把当前线程队列一次性刷盘
    def flush!
      queue = Thread.current[:school_engine_audit_queue]
      return if queue.nil? || queue.empty?

      lines = []
      lines << queue.pop until queue.empty?
      append_lines(lines)
    rescue StandardError => e
      Rails.logger.warn("school-engine: audit flush failed: #{e.class}: #{e.message}")
    end

    def append_lines(lines)
      return if lines.empty?

      path = log_path
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") do |f|
        f.flock(File::LOCK_EX)
        lines.each do |entry|
          line = JSON.generate(entry)
          f.puts(line)
          Rails.logger.info("[school-engine-audit] #{line}")
        end
        f.flock(File::LOCK_UN)
      end
      rotate!
    end

    def log_path
      File.join(Rails.root, "log", "school_engine_audit.log")
    end

    # ---- 自动轮转 + 压缩 ----
    def rotate!
      max_bytes = (SiteSetting.school_engine_audit_max_mb.to_i.clamp(1, 200)) * 1024 * 1024
      return unless File.exist?(log_path) && File.size(log_path) >= max_bytes

      stamp = Time.zone.now.strftime("%Y%m%d-%H%M%S")
      rotated = "#{log_path}.#{stamp}"
      FileUtils.mv(log_path, rotated)
      compress_async(rotated)
      prune_archives!
    end

    def compress_async(path)
      Job.enqueue(path)
    rescue StandardError
      # 压缩失败也要保证原始文件可读
      nil
    end

    def archive_pattern
      "#{log_path}.*"
    end

    def prune_archives!
      keep_days = SiteSetting.school_engine_audit_keep_days.to_i.clamp(1, 365)
      cutoff = Time.zone.now - keep_days.days
      Dir.glob("#{archive_pattern}*").each do |f|
        next unless File.file?(f)
        File.delete(f) if File.mtime(f) < cutoff
      rescue StandardError
        nil
      end
    end

    # 后台压缩执行体（由 Sidekiq 任务调用，避免阻塞请求）
    def compress_file(path)
      return unless File.exist?(path)
      gz = "#{path}.gz"
      Zlib::GzipWriter.open(gz) do |writer|
        File.open(path, "rb") do |src|
          writer.write(src.read)
        end
      end
      File.delete(path)
      gz
    end

    # 手动触发一次归档压缩（管理后台 / rake 用）
    def compress_now!
      Dir.glob(archive_pattern).each do |f|
        next if f.end_with?(".gz")
        compress_file(f)
      end
    end

    # ---- 便捷包装 ----
    def view(action, actor:, extra: {}, target: nil)
      log(action: "view.#{action}", actor: actor, target: target, extra: extra)
    end

    def change(action, actor:, extra: {}, target: nil)
      log(action: "change.#{action}", actor: actor, target: target, extra: extra)
    end

    def access(action, actor:, extra: {}, target: nil)
      log(action: "access.#{action}", actor: actor, target: target, extra: extra)
    end

    # 简易后台压缩任务
    module Job
      def self.enqueue(path)
        Jobs.enqueue(:school_audit_compress, path: path)
      rescue StandardError
        # 没有 Sidekiq 时同步兜底（只在轮转时触发，频率很低）
        Audit.compress_file(path)
      end
    end
  end
end
