import Component from "@glimmer/component";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import SiteSetting from "discourse/lib/site-settings";
import { i18n } from "discourse-i18n";

/**
 * 表达空间回帖身份选择：显示昵称 / 匿名。
 * 写入 composer.schoolAnonymous，经 serializeOnCreate → 请求参数 school_anonymous
 * → 后端仅对表达空间分类的回帖（post_number>1、学生身份）生效。
 * OP（createTopic）、staff、教师、非表达空间分类均不显示。
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

  get shouldShow() {
    return (
      this.composer?.action === "reply" &&
      !this.currentUser?.staff &&
      !this.currentUser?.school_teacher &&
      this.categorySlug === SiteSetting.school_engine_expression_category
    );
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
      </div>
    {{/if}}
  </template>
}
