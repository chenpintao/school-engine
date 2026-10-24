# frozen_string_literal: true

module SchoolEngine
  # 匿名访问首页时的服务端登录兜底。
  #
  # 背景（Discourse 核心设计，见 lib/homepage_helper.rb）：
  #
  #     def self.resolve(request = nil, current_user = nil)
  #       return "blank" if !current_user && SiteSetting.login_required?
  #
  # login_required = true 时，匿名访客的首页被强制解析为 "blank"，路由到
  # HomePageController#blank，直接渲染一个只含加载动画的空白页（HTTP 200）。
  # "跳转到登录页"这件事完全交给前端 discovery.login-required 路由完成。
  #
  # 这条前端链路一旦失败（JS 未加载完、跨境网络抖动、路由被插件接管等），
  # 用户就会永久停在"四个点一直转"的空白页。
  #
  # 本补丁在服务端接管：匿名 + login_required 的首页请求直接 302 到校园登录页，
  # 不依赖任何前端逻辑。只在 HomePageController#blank 上生效，不影响其他路由。
  module LoginRedirect
    def blank
      if SiteSetting.login_required? && !current_user
        flash.keep
        return redirect_to(path("/school/login"))
      end
      super
    end
  end

  # 其它需要登录的页面（/latest、/categories、/t/:id、/u/:name 等）核心会
  # 302 到 /login。统一改指校园登录页，避免用户看到两套不同的登录界面。
  module CoreLoginEntryPoint
    def redirect_to_login_if_required
      if school_engine_school_login_target?
        flash.keep
        cookies[:destination_url] = request.fullpath
        return redirect_to(path("/school/login"))
      end
      super
    end

    # 核心 ensure_logged_in 只是 raise NotLoggedIn，随后由 rescue_from 渲染
    # 404 页面（include_ember）并靠前端跳到 /login。这里直接接管，省掉整条链路。
    def ensure_logged_in
      if school_engine_school_login_target?
        flash.keep
        cookies[:destination_url] = request.fullpath
        redirect_to path("/school/login")
        return
      end
      super
    end

    def redirect_to_login
      if school_engine_school_login_target?
        flash.keep
        cookies[:destination_url] = request.fullpath
        return redirect_to(path("/school/login"))
      end
      super
    end

    private

    def school_engine_school_login_target?
      return false if current_user
      return false unless SiteSetting.login_required
      return false unless request.get?
      return false if request.xhr?
      return false if is_api? || is_user_api?
      # 注意：不能只用 request.format.html? 判断。curl / 部分客户端不发 Accept 头时
      # format 为 */*，html? 为 false。这里改为"排除法"：只要不是 JSON/RSS 等
      # 明确的数据格式，就当作浏览器页面请求处理。
      fmt = request.format.to_s
      return false if %w[json rss atom xml text].include?(fmt.split("/").last.to_s)
      return false if request.path.to_s.end_with?(".json", ".rss", ".xml")

      p = request.path.to_s
      return false if p.start_with?("/school/")
      return false if p.start_with?("/session/")
      return false if p.start_with?("/auth/")
      true
    end
  end
end
