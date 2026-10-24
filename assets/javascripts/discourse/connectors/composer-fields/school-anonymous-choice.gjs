import Component from "@glimmer/component";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { i18n } from "discourse-i18n";

/**
 * 匿名身份控件（composer-fields outlet），分类行为全部来自
 * 原生站点设置 siteSettings.school_engine_category_rules（list 型，每行 "slug:mode"）：
 * - forced 强制：发主题或回帖、任何身份都整分类匿名，仅提示，无需也不接受选择；
 *   服务端 post_created 无条件打匿名标记。
 * - optional 可选：仅回帖（reply）、非 staff、非教师可见昵称 / 匿名二选一，
 *   写 composer.schoolAnonymous。
 * - disabled/未配置：不显示。
 * 规则完全来自站点设置（默认值在 settings.yml 中预设，后台可清空）；为空时不显示控件。
 */

// 班级圈板块（xx-class-2029-1 / cz-class-2029-3 等）默认且强制不匿名
const CLASS_CIRCLE_SLUG_REGEX = /^(?:xx|cz)-class-\d{4}-/;

const parseRuleLines = (lines) =>
  // Discourse list 设置以 "|" 分隔存储；同时兼容换行（textarea 粘贴）
  (Array.isArray(lines) ? lines : String(lines || "").split(/[|\n]/))
    .map((line) => {
      const [slug, mode] = line.split(":");
      return { slug: slug?.trim(), mode: mode?.trim() };
    })
    .filter((rule) => rule.slug && ["forced", "optional", "disabled"].includes(rule.mode));

export default class SchoolAnonymousChoice extends Component {
  @service currentUser;
  @service site;
  @service siteSettings;

  get composer() {
    return this.args.outletArgs?.model;
  }

  get categorySlug() {
    const id = this.composer?.categoryId;
    return this.site.categories?.findBy?.("id", id)?.slug;
  }

  get rules() {
    // 规则完全来自站点设置；为空（清空设置）时不显示任何匿名控件
    return parseRuleLines(this.siteSettings.school_engine_category_rules);
  }

  get mode() {
    if (CLASS_CIRCLE_SLUG_REGEX.test(this.categorySlug || "")) {
      return "disabled";
    }
    return this.rules.find((rule) => rule.slug === this.categorySlug)?.mode;
  }

  get isWall() {
    return this.mode === "forced";
  }

  get isExpressionReply() {
    return (
      this.mode === "optional" &&
      this.composer?.action === "reply" &&
      !this.currentUser?.staff &&
      !this.currentUser?.school_teacher
    );
  }

  get shouldShow() {
    if (this.isWall) {
      return ["reply", "createTopic"].includes(this.composer?.action);
    }
    return this.isExpressionReply;
  }

  get useNickname() {
    return this.composer?.schoolAnonymous !== true;
  }

  get useAnonymous() {
    return this.composer?.schoolAnonymous === true;
  }

  @action
  choose(event) {
    this.composer?.set("schoolAnonymous", event.target.value === "anonymous");
  }

  <template>
    {{#if this.shouldShow}}
      <div class="school-anonymous-choice">
        {{#if this.isWall}}
          <span class="school-anonymous-choice-title">
            {{i18n "school_engine.wall_identity"}}
          </span>
          <label class="school-anonymous-choice-option is-locked">
            <input type="radio" name="school-anonymous-choice" value="anonymous" checked disabled />
            {{i18n "school_engine.wall_choice_anonymous"}}
          </label>
          <p class="school-anonymous-choice-hint">
            {{i18n "school_engine.wall_anonymous_hint"}}
          </p>
        {{else}}
          <span class="school-anonymous-choice-title">
            {{i18n "school_engine.expression_identity"}}
          </span>
          <label class="school-anonymous-choice-option">
            <input
              type="radio"
              name="school-anonymous-choice"
              value="nickname"
              checked={{this.useNickname}}
              {{on "change" this.choose}}
            />
            {{i18n "school_engine.expression_choice_nickname"}}
          </label>
          <label class="school-anonymous-choice-option">
            <input
              type="radio"
              name="school-anonymous-choice"
              value="anonymous"
              checked={{this.useAnonymous}}
              {{on "change" this.choose}}
            />
            {{i18n "school_engine.expression_choice_anonymous"}}
          </label>
          <p class="school-anonymous-choice-hint">
            {{i18n "school_engine.expression_anonymous_hint"}}
          </p>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
