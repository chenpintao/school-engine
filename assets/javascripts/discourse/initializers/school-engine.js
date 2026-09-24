import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";
import SchoolJuniorClassModal from "discourse/plugins/school-engine/discourse/components/school-junior-class-modal";
import SchoolFeatureButton from "discourse/plugins/school-engine/discourse/components/school-feature-button";

export default {
  name: "school-engine",
  initialize() {
    withPluginApi("1.13.0", (api) => {
        const currentUser = api.getCurrentUser();

        // 侧边栏链接工厂：所有链接同构（name/text/title + icon 前缀 + route 或 href）
        const buildLink = (BaseLink, def) =>
          class extends BaseLink {
            get name() {
              return def.name;
            }
            get text() {
              return def.text;
            }
            get title() {
              return def.text;
            }
            get route() {
              return def.route;
            }
            get href() {
              return def.href;
            }
            get prefixType() {
              return "icon";
            }
            get prefixValue() {
              return def.icon;
            }
          };

        // 同学录/班级圈/班级管理：左侧菜单（必须传 panelKey "main"，否则 section 被静默丢弃）
        api.addSidebarSection(
          (BaseSection, BaseLink) => {
            const linkDefs = [
              { name: "school-directory", text: "同学录", route: "school-directory", icon: "address-book" },
              { name: "school-classes", text: "班级圈", route: "groups", icon: "user-group" },
              { name: "school-manage", text: "班级管理", route: "school-manage", icon: "users" },
            ];
            if (currentUser?.staff) {
              linkDefs.push({ name: "school-config", text: "插件配置", route: "school-config", icon: "gear" });
            }
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
                return linkDefs.map((def) => buildLink(BaseLink, def));
              }
            };
          },
          "main"
        );

      // 班级管理：admin 管理菜单入口
      api.addAdminSidebarSectionLink("root", {
        name: "school-classes",
        route: "admin.schoolClasses",
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
        if (p === "/login" || p === "/login/") {
          window.location.replace("/school/login");
          return;
        }
        if (p === "/signup" || p === "/signup/") {
          window.location.replace("/school/register");
          return;
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
