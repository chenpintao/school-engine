import Component from "@glimmer/component";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import SiteSetting from "discourse/lib/site-settings";
import { i18n } from "discourse-i18n";

/**
 * 匿名身份控件（composer-fields outlet）：
 * - 全校表达空间（回帖、学生）：显示昵称 / 匿名 二选一，写 composer.schoolAnonymous
 * - 匿名墙（发主题或回帖，任何身份）：整分类强制匿名，仅提示，无需也不接受选择；
 *   服务端 post_created 无条件打匿名标记。
 * OP（createTopic）、staff、教师、其他分类均不显示表达空间选择器。
 */
export default class SchoolAnonymousChoice extends Component {
  @service currentUser;
  @service site;

  get composer() {
    return this.args.outletArgs?.model;
  }

  get categorySlug() {
    const id = this.composer?.categoryId;
    return this.site.categories?.findBy?.("id", id)?.slug;
  }

  get isWall() {
    return this.categorySlug === SiteSetting.school_engine_wall_category;
  }

  get isExpressionReply() {
    return (
      this.composer?.action === "reply" &&
      !this.currentUser?.staff &&
      !this.currentUser?.school_teacher &&
      this.categorySlug === SiteSetting.school_engine_expression_category
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
