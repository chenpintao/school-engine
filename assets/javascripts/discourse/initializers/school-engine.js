import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";
import SchoolJuniorClassModal from "discourse/plugins/school-engine/discourse/components/school-junior-class-modal";
import SchoolFeatureButton from "discourse/plugins/school-engine/discourse/components/school-feature-button";
import SchoolReportButton from "discourse/plugins/school-engine/discourse/components/school-report-button";


// ---------------------------------------------------------------------------
// 启动容错（全局，只执行一次）
// 任何插件/主题的 initializer 抛错都会中断 Ember 启动，表现为页面永久停在
// 加载动画（四个点）。这里对常见的"API 不存在"这类错误做兜底：
// 捕获尚未处理的 promise 异常，避免其升级为启动失败。
// 注意：只记录不吞掉真实错误，正常错误仍会打印到控制台便于排查。
// ---------------------------------------------------------------------------
if (typeof window !== "undefined" && !window.__schoolEngineBootGuard) {
  window.__schoolEngineBootGuard = true;

  const isApiDriftError = (err) => {
    const msg = String(err?.message || err || "");
    return (
      msg.includes("is not a function") ||
      msg.includes("Unknown transformer") ||
      msg.includes("is unknown and will be ignored")
    );
  };

  window.addEventListener("unhandledrejection", (event) => {
    if (isApiDriftError(event.reason)) {
      // eslint-disable-next-line no-console
      console.warn(
        "[school-engine] 已隔离插件 API 不兼容异常（不影响页面加载）:",
        event.reason?.message || event.reason
      );
      event.preventDefault();
    }
  });
}

export default {
  name: "school-engine",
  initialize() {
    withPluginApi("1.13.0", (api) => {
        const currentUser = api.getCurrentUser();

        // 登录/注册：路由进入前客户端替换（同 SPA 内 transitionTo，无整页二次跳转）
        // 邀请链接进入原生 signup 时保留全部查询参数（invite_token 等），交给校园注册向导
        const router = api.container.lookup("service:router");
        router.on("routeWillChange", (transition) => {
          const name = transition.to?.name;
          // "discovery.login-required" 是 login_required 站点的首页目标路由（核心无独立模板，
          // 依赖原生 login 页兜底）。这里一并接管，否则匿名用户会停在空白页（四个点转圈）。
          if (name === "login" || name === "discovery.login-required") {
            transition.abort();
            router.transitionTo("school-login");
          }
          else if (name === "signup") {
            transition.abort();
            // 透传邀请参数（核心 signup 的 queryParams 可能叫 inviteToken/invite_token），
            // 用 URL 字符串跳转避免自定义路由未声明 queryParams 的兼容问题
            const search = window.location.search || "";
            router.transitionTo(`/school/register${search}`);
          }
        });

        // 侧边栏链接工厂：所有链接同构（name/text/title + icon 前缀 + route 或 href）
        // 注意：必须用类字段，不能用 getter——核心 BaseLink 构造函数会以 own
        // property 写入同名字段，遮蔽子类 prototype getter（表现为空白 # 链接）。
        const buildLink = (BaseLink, def) =>
          class extends BaseLink {
            name = def.name;
            text = def.text;
            title = def.text;
            route = def.route;
            href = def.href;
            prefixType = "icon";
            prefixValue = def.icon;
          };

        // 同学录/班级管理：左侧菜单（必须传 panelKey "main"，否则 section 被静默丢弃）
        api.addSidebarSection(
          (BaseSection, BaseLink) => {
            const linkDefs = [
              { name: "school-directory", text: "同学录", route: "school-directory", icon: "address-book" },
              { name: "school-manage", text: "班级管理", route: "school-manage", icon: "users" },
              ...(currentUser && (currentUser.staff || currentUser.can_review_reports)
                ? [{ name: "school-review", text: "审核复核台", route: "school-review", icon: "shield-alt" }]
                : []),
            ];
            if (currentUser) {
              linkDefs.push({
                name: "school-me",
                text: "我的",
                href: `/u/${currentUser.username}/preferences/profile`,
                icon: "user",
              });
            } else {
              linkDefs.push(
                { name: "school-login", text: "登录", route: "school-login", icon: "sign-in-alt" },
                { name: "school-register", text: "注册", route: "school-register", icon: "user-plus" }
              );
            }

            return class extends BaseSection {
              get name() {
                return "school";
              }
              get text() {
                return "校园";
              }
              get links() {
              // 核心按实例读取属性（link.text / link.href …），必须 new，
              // 返回类会得到空白 # 链接。
              return linkDefs.map((def) => new (buildLink(BaseLink, def))());
            }
            };
          },
          "main"
        );

      // 班级管理：admin 管理菜单入口（直接进管理页，不再注册独立 admin 路由）
      api.addAdminSidebarSectionLink("root", {
        name: "school-classes",
        href: "/school/manage",
        label: "school_engine.admin_menu_label",
        description: "school_engine.admin_menu_description",
        icon: "users",
      });

      // "不给老师看"开关：composer.schoolHideFromStaff → 创建主题请求参数
      // school_hide_from_staff（参照 discourse-post-voting 的官方模式，
      // 后端经 add_permitted_post_create_param 放行，避免弃用的 meta_data 通道）
      api.serializeOnCreate("school_hide_from_staff", "schoolHideFromStaff");
      // 表达空间回帖匿名：composer.schoolAnonymous → school_anonymous 请求参数
      api.serializeOnCreate("school_anonymous", "schoolAnonymous");
      // 班级通知：composer.schoolClassNotice → school_class_notice 请求参数
      api.serializeOnCreate("school_class_notice", "schoolClassNotice");

      // 帖子菜单：staff 精选/取消精选（新版 glimmer post menu DAG；组件内部按分类+回帖条件自渲染）
      api.registerValueTransformer("post-menu-buttons", ({ value: dag, context }) => {
        dag.add("school-feature", SchoolFeatureButton, {
          after: context.firstButtonKey,
        });
        // 固定一键举报入口（所有登录用户，帖子菜单常驻）
        dag.add("school-report", SchoolReportButton, {
          after: context.firstButtonKey,
        });
      });

      // ---- 编辑器简洁 / 高级模式 ----
      // 纯展示层方案：body 加 school-composer-mode--simple / --advanced 类，
      // 简洁模式由 SCSS 隐藏 Markdown/富文本按钮（display:none 可逆，不改编辑器任何逻辑），
      // 只保留 .upload 上传/拍照按钮；切换滑块注入到工具栏内，视觉对齐核心自带滑块。
      const COMPOSER_MODE_KEY = "schoolComposerMode";

      const composerMode = () =>
        localStorage.getItem(COMPOSER_MODE_KEY) === "advanced" ? "advanced" : "simple";

      const syncComposerSwitch = (button, mode) => {
        const advanced = mode === "advanced";
        button.classList.toggle("is-advanced", advanced);
        button.setAttribute("aria-checked", advanced ? "true" : "false");
        const label = i18n(
          advanced
            ? "school_engine.composer_mode_to_simple"
            : "school_engine.composer_mode_to_advanced"
        );
        button.title = label;
        button.setAttribute("aria-label", label);
        button
          .querySelector(".school-composer-mode-switch__icon--simple")
          ?.classList.toggle("--active", !advanced);
        button
          .querySelector(".school-composer-mode-switch__icon--advanced")
          ?.classList.toggle("--active", advanced);
      };

      const applyComposerMode = (mode) => {
        document.body.classList.toggle("school-composer-mode--simple", mode === "simple");
        document.body.classList.toggle("school-composer-mode--advanced", mode === "advanced");
        document
          .querySelectorAll(".school-composer-mode-switch")
          .forEach((button) => syncComposerSwitch(button, mode));
      };

      // 把滑块挂到工具栏内（与按钮同一父容器）；工具栏重渲染时幂等重挂
      const mountComposerSwitch = (bar) => {
        if (!bar || bar.querySelector(".school-composer-mode-switch")) {
          return;
        }
        const anchor = bar.querySelector(
          ".toolbar__button, .toolbar-separator, .composer-toggle-switch"
        );
        const container = anchor ? anchor.parentElement : bar;

        const button = document.createElement("button");
        button.type = "button";
        button.className = "school-composer-mode-switch";
        button.setAttribute("role", "switch");
        button.innerHTML = `
          <span class="school-composer-mode-switch__slider">
            <span class="school-composer-mode-switch__icon school-composer-mode-switch__icon--simple" aria-hidden="true">
              <svg class="fa d-icon svg-icon svg-string"><use href="#pencil"></use></svg>
            </span>
            <span class="school-composer-mode-switch__thumb"></span>
            <span class="school-composer-mode-switch__icon school-composer-mode-switch__icon--advanced" aria-hidden="true">
              <svg class="fa d-icon svg-icon svg-string"><use href="#fab-markdown"></use></svg>
            </span>
          </span>`;
        button.addEventListener("click", () => {
          const next = composerMode() === "simple" ? "advanced" : "simple";
          localStorage.setItem(COMPOSER_MODE_KEY, next);
          applyComposerMode(next);
        });

        container.appendChild(button);
        syncComposerSwitch(button, composerMode());
      };

      // 编辑器首次打开或核心重渲染工具栏时自动挂载
      const composerObserver = new MutationObserver((mutations) => {
        mutations.forEach((mutation) => {
          mutation.addedNodes.forEach((node) => {
            if (node.nodeType !== Node.ELEMENT_NODE) {
              return;
            }
            if (node.classList?.contains("d-editor-button-bar")) {
              mountComposerSwitch(node);
            }
            node
              .querySelectorAll?.(".d-editor-button-bar")
              .forEach(mountComposerSwitch);
          });
        });
      });
      composerObserver.observe(document.body, { childList: true, subtree: true });

      document.querySelectorAll(".d-editor-button-bar").forEach(mountComposerSwitch);
      applyComposerMode(composerMode());

      const checked = "__school_junior_checked__";

      // 匿名帖：禁止点击头像/用户名跳转个人主页（全局只需注册一次，避免 onPageChange 累积监听器）
      // 覆盖历史"匿名用户"与表达空间"匿名同学X"（原始链接与 URL 编码两种形态）
      document.addEventListener(
        "click",
        (e) => {
          const a = e.target.closest?.(
            "a[href*='%E5%8C%BF%E5%90%8D%E7%94%A8%E6%88%B7'], a[href*='u/匿名用户'], a[href*='%E5%8C%BF%E5%90%8D%E5%90%8C%E5%AD%A6'], a[href*='u/匿名同学']"
          );
          if (a) {
            e.preventDefault();
            e.stopPropagation();
          }
        },
        true
      );

      api.onPageChange(() => {
        // 登录/注册入口统一指向自定义页面（覆盖 header 按钮、/login /signup 路由、直接访问）
        const p = window.location.pathname;

        // 邀请链接（/invites/:token）：未登录用户直接进入校园注册向导，
        // 让其完成学籍信息采集；已登录用户保留原生流程（直接接受邀请）
        const inviteMatch = p.match(/^\/invites\/([A-Za-z0-9]+)/);
        if (inviteMatch && !api.getCurrentUser()) {
          const qs = new URLSearchParams(window.location.search);
          const target = `/school/register?invite_token=${encodeURIComponent(inviteMatch[1])}`;
          const extra = qs.toString();
          window.location.replace(extra ? `${target}&${extra}` : target);
          return;
        }

        // 班级圈群组页：非 staff 隐藏成员入口与人数（服务端 members 接口已 404，这里仅视觉隐藏）
        const circleGroup = p.match(/^\/g\/((?:xx|cz)-\d{4}-)/);
        const hideCircleMembers =
          !!circleGroup && !api.getCurrentUser()?.staff;
        document.body.classList.toggle("school-circle-group", hideCircleMembers);
        if (hideCircleMembers) {
          // 不依赖具体 DOM 类名：找到指向本班成员页的链接，连同其 tab 容器一起隐藏
          requestAnimationFrame(() => {
            document
              .querySelectorAll('a[href^="/g/xx-"][href$="/members"], a[href^="/g/cz-"][href$="/members"]')
              .forEach((link) => {
                link.style.setProperty("display", "none", "important");
                link
                  .closest('li, [role="tab"], .navigation-tab, .d-button')
                  ?.style.setProperty("display", "none", "important");
              });
          });
        }
        // 个人设置保留原生框架：profile 内容由插件注入（user-preferences-profile outlet）

        // 小升初选班检测（登录用户，只查一次）
        const user = api.getCurrentUser();
        if (!user || window[checked]) return;
        window[checked] = true;

        ajax("/school/junior-class-status.json")
          .then((data) => {
            if (data && data.needs) {
              const modal = api.container.lookup("service:modal");
              modal.show(SchoolJuniorClassModal, {
                model: { classes: ["1班", "2班", "3班", "4班", "5班", "6班"] },
              });
            }
          })
          .catch(() => {});
      });
    });
  },
};
