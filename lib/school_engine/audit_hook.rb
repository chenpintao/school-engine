# frozen_string_literal: true

module SchoolEngine
  # 控制器统一审计钩子
  #
  # 记录插件所有接口的访问：谁、做了什么、HTTP 状态、耗时、参数概要（脱敏）。
  #
  # 实现要点：
  #  - prepend_before_action：把"开始计时"插到回调链最前面，
  #    即使后续 before_action（如 requires_login）抛 403 也能留痕
  #  - after_action + rescue_from 兜底：正常结束和异常结束都会写一条
  #  - 同步写文件：单条几百字节，开销远小于一次 DB 查询，保证不丢
  module AuditHook
    extend ActiveSupport::Concern

    included do
      prepend_before_action :school_engine_audit_begin
      after_action :school_engine_audit_finish
    end

    private

    def school_engine_audit_begin
      return unless SchoolEngine::Audit.enabled?
      @_school_engine_audit_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Thread.current[:school_engine_audit_req] = request
      true
    end

    def school_engine_audit_finish(error: nil, error_type: nil, status_code: nil)
      return unless SchoolEngine::Audit.enabled?
      return if @_school_engine_audit_done
      return if @_school_engine_audit_started.nil?

      @_school_engine_audit_done = true
      elapsed =
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @_school_engine_audit_started) * 1000)
          .round(1)

      entry = {
        "ts" => Time.zone.now.iso8601(3),
        "action" => "api.#{controller_name}##{action_name}",
        "actor_id" => current_user&.id,
        "actor" => current_user&.username,
        "actor_staff" => current_user&.staff?,
        "target" => nil,
        "ip" => request.remote_ip,
        "ua" => request.user_agent.to_s[0, 160],
        "request_id" => request.request_id,
        "method" => request.method,
        "path" => request.path,
        "status" => status_code || response.status,
        "ms" => elapsed,
        "params" => SchoolEngine::Audit.sanitize_hash(school_engine_audit_params),
      }
      entry["error"] = "#{error.class}: #{error.message.to_s[0, 200]}" if error
      entry["error_type"] = error_type.to_s if error_type

      SchoolEngine::Audit.write_entry(entry)
    rescue StandardError => e
      Rails.logger.warn("school-engine: audit hook failed: #{e.class}: #{e.message}")
    ensure
      Thread.current[:school_engine_audit_req] = nil
    end

    # 覆盖 Discourse 的错误渲染入口：403/404/500 等异常路径也留痕
    def rescue_discourse_actions(type, status_code, opts = nil)
      begin
        school_engine_audit_finish(error_type: type, status_code: status_code)
      rescue StandardError
        nil
      end
      super
    end

    def school_engine_audit_params
      request.params.except("controller", "action", "format").to_h.first(15).to_h
    rescue StandardError
      {}
    end
  end
end
