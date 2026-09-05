# frozen_string_literal: true

module SchoolEngine
  # 注册/登录/个人资料/同学录/管理页：渲染 SPA shell，实际内容由前端插件路由渲染
  class SchoolEnginePagesController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    # 登录/注册页允许匿名访问；其余页面（profile/directory/admin）仍走原生登录校验
    skip_before_action :check_xhr, :redirect_to_login_if_required, only: %i[register login]
    before_action :redirect_if_logged_in, only: %i[register login]
    # 纵深防御：admin 页面除路由层 StaffConstraint 外，控制器层再走一次 guardian
    before_action :ensure_staff_page, only: :admin_page

    # GET /school/register
    def register
      render "school_engine_pages/spa", layout: "application"
    end

    # GET /school/login
    def login
      render "school_engine_pages/spa", layout: "application"
    end

    # GET /school/profile
    def profile
      render "school_engine_pages/spa", layout: "application"
    end

    # GET /school/directory
    def directory
      render "school_engine_pages/spa", layout: "application"
    end

    # GET /admin/school-classes（admin 管理菜单进入，SPA shell；StaffConstraint + guardian 双重校验）
    def admin_page
      render "school_engine_pages/spa", layout: "application"
    end

    # GET /school/manage（班级管理组入口，页面壳；数据 API 在控制器层做 school_admin 校验）
    def manage
      render "school_engine_pages/spa", layout: "application"
    end

    private

    def redirect_if_logged_in
      redirect_to "/" if current_user.present?
    end

    def ensure_staff_page
      guardian.ensure_staff!
    end
  end
end
